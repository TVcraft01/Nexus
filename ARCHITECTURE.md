# Architecture

How Nexus is shaped, who owns what, and where a change should land. Written
after the extraction pass that split the answer catalog out of the routing
service and gave inbound memory a single owner — later passes should build
with these seams, not against them.

## Layers

Three layers, one-way data flow:

```
input ──> ui/           presentation + platform dispatch (widgets, method
            │           channels, native backends)
            v
        core/           pure logic: parse → route → answer → memory
            │           (no Flutter widgets; store/mesh are the only IO)
            v
        mesh/           transport + sync (pairing, relay, serial bridge)
```

`core` never imports `ui` or `mesh`. `mesh` never imports `ui`. `ui` wires
everything: it owns the *composition* — constructing the service from the
store, registering the mesh's inbound callbacks, forwarding actions to
native backends.

Within `core`, the assistant pipeline is:

```
CommandInterpreter ──> CommandService ──> answers.localAnswer
   text → ParsedCommand   routing, approval,   the catalog: what the
                          clarification,        assistant says per action
                          device plans,         (pure over AnswerContext)
                          memory lifecycle
```

## Module map (lib/)

| File | Lines | Owns |
|---|---|---|
| `core/agent_contract.dart` | ~466 | The vocabulary: `ParsedCommand`, `AgentMessage`, `AgentDispatch`, actions, device snapshots. No behavior. |
| `core/command_interpreter.dart` | ~1,430 | Text → `ParsedCommand`: patterns for every action, normalization, phrase similarity. Pure. |
| `core/command_service.dart` | ~770 | **Routing + assistant state**: execute pipeline, taught phrases/learned defaults (`_learned`/`_defaults`), clarification state machines, approval + device plans, remote requests. The service is deliberately store-agnostic — constructed with an `AgentMemory` value, mutations surfaced through callbacks. |
| `core/answers.dart` | ~870 | **The local answer catalog**: `localAnswer(command, ctx)` — a flat switch over actions deciding the assistant's words, plus its pure helpers (fact matching `factsAbout`/`contactNumber`, phone extraction with the E.164 cap, time/number formatting, `evaluateMath`). Routing stays in the service; only answers live here. |
| `core/dream.dart` | ~60 | The dream pass: mines the ask log for phrases the assistant missed. Pure. |
| `core/query_log.dart` | ~170 | Append-only ask log + read-back, with `@visibleForTesting` seams for fake-async tests. |
| `core/store.dart` | ~270 | JSON persistence (`NexusStore`). The store is a *mirror* — setter + `save()`, no logic — plus identity/devices/files metadata. |
| `mesh/mesh_service.dart` | ~3,200 | Mesh transport, pairing, sync handlers, remote file access, clipboard. Its size is next on the chopping block. |
| `ui/device_executor.dart` | ~1,180 | **The device executor**: every platform action this device can run (apps, screenshots, calls, texts, media, timers…) and the switch routing an `AgentRequest` to the right one. Injectable backends — unit-tested without widgets (`test/device_executor_test.dart`). |
| `ui/assistant_view.dart` | ~1,550 | The assistant screen: thread UI, service wiring, mesh/approval flows. It decides *what* the assistant says and when to run; `DeviceExecutor` decides *how* an action runs. The dream sheet and clock are still extractable here. |

## State ownership

- **Session memory** (taught phrases, defaults, facts) is owned by
  `CommandService`'s private maps/lists, seeded from an `AgentMemory` at
  construction and mutated only through its methods (`learn`, `remember`
  via the catalog, `adoptLearned`, `adoptFact`, forget).
- **Persisted memory** is owned by `NexusStore`. The `onMemoryChanged`
  callback — wired in `assistant_view` — is the *single funnel*: the view
  copies the service's snapshots into the store and saves. The service
  never touches the store; the store never reaches into the service.
- **Inbound mesh knowledge** follows one rule (see the doc on
  `MeshService.onFactReceived`): the mesh only *delivers* to a live
  listener, and the claiming listener's own funnel writes the store. When
  no listener is attached (startup window, headless mesh), the mesh writes
  the store itself so knowledge survives for the next boot. One writer per
  event — never both.

## Where a change lands

- A new thing the assistant can *say* → add a case in `answers.dart`
  (`localAnswer`) and a pattern in `command_interpreter.dart` if a new
  phrasing is needed. Only touch `command_service.dart` when routing,
  approval, or state semantics change.
- A new *memory* kind → follow the facts vertical: interpreter pattern →
  catalog case mutating through `AnswerContext` → a `NexusStore` field →
  a mesh message type + inbound handler.
- A new *platform action* ("open x", "toggle y") → `ui/device_executor.dart`:
  add the method and one route in its switch. Platform code never lives in
  the view or the catalog.
- A new *device-offered action* (a call/text this device can't run but a
  paired one can) → follow the contact vertical: the service fork in
  `_contactAction` decides local-vs-offer-vs-catalog, `_routeDeviceAction`
  asks/remembers the device, and the approved remote plan auto-sends via
  Path 3 in the view (`_consume`); the paired device re-gates the incoming
  request in its own view (`_handleIncoming`) and runs its real executor.
  Widen the fork's action set only with the receiver's capability in mind.
- A behavior change to sync or pairing → `mesh/`. A new screen → `ui/`, in
  its own file, not appended to `assistant_view.dart`.
- Answers that need more than the catalog's `AnswerContext` (facts +
  devices + memory callbacks) should widen the context, not thread service
  internals back in.

## Known debt (do not grow)

- `mesh/mesh_service.dart` (3.2k) is now the last monolith; extract by
  concern (relay vs pairing vs sync vs file serving) before adding to it.
  Its parts share one state object, so split state with the seams, not
  around them.
- `ui/assistant_view.dart` (1.5k) still holds the dream sheet, the live
  clock, and `_ThreadEntry` next to the conversation UI; extracting them
  into their own files is the next clean slice.
- `handleRemoteRequest` in `command_service.dart` keeps its own small
  answer switch rather than delegating to the catalog — shared wording
  between the two is duplicated, not yet collapsed.
