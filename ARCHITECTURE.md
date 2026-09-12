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
| `core/agent_contract.dart` | 471 | The vocabulary: `ParsedCommand`, `AgentMessage`, `AgentDispatch`, action ids, device snapshots. No behavior, and no platform policy — that moved to `capability.dart`. |
| `core/capability.dart` | 246 | **The capability registry**: one entry per action with its label, its verified example and the platforms whose executor can run it, plus the derived views other layers read — `skillCatalog()` (ranking), `suggestionExamples()` (chips), `defaultCapabilitiesFor(platform)` (what this device offers peers). |
| `core/command_interpreter.dart` | 2557 | Text → `ParsedCommand`: patterns for every action, normalization, phrase similarity. Pure. |
| `core/command_service.dart` | 969 | **Routing + assistant state**: execute pipeline, taught phrases/learned defaults (`_learned`/`_defaults`), clarification state machines, approval + device plans, remote requests. The service is deliberately store-agnostic — constructed with an `AgentMemory` value, mutations surfaced through callbacks. |
| `core/answers.dart` | 1382 | **The local answer catalog**: `localAnswer(command, ctx)` — a flat switch over actions deciding the assistant's words, plus its pure helpers (fact matching `factsAbout`/`contactNumber`, phone extraction with the E.164 cap, time/number formatting, `evaluateMath`). Routing stays in the service; only answers live here. |
| `core/dream.dart` | ~150 | The dream pass: mines the ask log for phrases the assistant missed, and (since the self-improvement pass) proposes fixes for persistently re-asked phrases that match one the user already taught (`learnable`) — the meaning always comes from the user's own teaching, applied through the service's normal `learn` funnel. Pure. |
| `core/reminders.dart` | ~215 | **The reminder engine** (since the architecture pass): the model (`Reminder`), the decisions (`splitTime`, `dueNow`) and the lifecycle (`ReminderEngine` — the live list, the ticking due-check, the one-shot fire). The engine is store/mesh-free: persistence, broadcast and thread messages are edge callbacks the view wires. |
| `core/query_log.dart` | ~170 | Append-only ask log + read-back, with `@visibleForTesting` seams for fake-async tests. |
| `core/store.dart` | ~270 | JSON persistence (`NexusStore`). The store is a *mirror* — setter + `save()`, no logic — plus identity/devices/files metadata. |
| `mesh/mesh_service.dart` | 3558 | Mesh transport, pairing, sync handlers, remote file access, clipboard. Its size is next on the chopping block. |
| `ui/device_executor.dart` | 1728 | **The device executor**: every platform action this device can run (apps, screenshots, calls, texts, media, timers…) and the switch routing an `AgentRequest` to the right one. Injectable backends — unit-tested without widgets (`test/device_executor_test.dart`). |
| `ui/assistant_view.dart` | 2773 | The assistant screen: thread UI, service wiring, mesh/approval flows. It decides *what* the assistant says and when to run; `DeviceExecutor` decides *how* an action runs. The reminder engine was extracted into `core/reminders.dart` (the view only renders its banner and wires its edges); the dream review sheet and the clock widget are still extractable here. |

## State ownership

- **Session memory** (taught phrases, defaults, facts) is owned by
  `CommandService`'s private maps/lists, seeded from an `AgentMemory` at
  construction and mutated only through its methods (`learn`, `remember`
  via the catalog, `adoptLearned`, `adoptFact`, forget).
- **Promises (reminders)** are owned by `ReminderEngine` (list, fired
  banner, timer, one-shot semantics). The view seeds it from the store,
  wires its `onPersist`/`onBroadcast`/`onFired` edges, and renders; the
  engine never touches the store or the mesh directly.
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

## The capability registry (one owner)

One fact about an action used to live in five places: the id in
`agent_contract.dart`, its label and example in `skills.dart`, the phrasing
in `command_interpreter.dart`, the per-platform default lists in
`agent_contract.dart`, and the wording in `answers.dart`. Five partial owners
let a suggestion chip name an action no device could run, and let a platform
list drift from the executor backing it.

`core/capability.dart` now owns the metadata and the derived views.
`AgentActions` stays the vocabulary, `command_interpreter.dart` stays the
parser, and `answers.dart` stays the wording. Two invariants are enforced by
`test/capability_test.dart` rather than merely documented:

- every `AgentActions` id has exactly one registry entry, and no entry names
  something that is not an action, and
- every non-null `Capability.example` parses back to its own action — so a
  chip or a ranked skill can never point at nothing.

Adding an action is therefore one checked edit in one file, not a five-file
sync. `capabilityFor(id)` is how any other layer asks what an action is.

## Where a change lands

- A new *capability* (anything the assistant can do) → declare it once in
  `core/capability.dart`: the id (an `AgentActions` constant), a label, and a
  verified example plus the platforms whose executor runs it. The ranking,
  the suggestion chips and what this device advertises to peers all follow
  from that entry; the tests fail if an example does not really parse.
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
- A new *timed behavior* ("remind me … at 8pm") → follow the reminder
  vertical: `core/reminders.dart` owns the words/times/due checks (pure,
  injectable clock), the view owns the list + scheduler + firing + mesh
  broadcast/adopt (`_registerReminder`/`_checkReminders`), the store mirrors
  it via `agentReminders`, and `agent.reminder` is the mesh message. The
  catalog parses the time and promises the echo; the engine does the rest.
- A new *input surface* (voice, camera, sensors) → follow the speech
  vertical: `core/speech.dart` is the thin seam (injectable, honest
  "not on this device" fallback), the view wires the button and submits
  the captured text through the same `_execute` pipeline as typing, and
  the real platform implementation lives behind a `dev.nexus.nexus/…`
  MethodChannel in `MainActivity.kt`. Fakes drive the whole flow in tests.
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
- `test/command_surface_test.dart` still restates advertised phrases. That is
  deliberate for *natural variants* (typos, fillers, "hey siri …"), but the
  canonical chip phrases belong to the registry and should be read from it.
- Most registry entries have no `example` yet. That is honest — a null
  example is a capability with no verified phrase, and it is skipped by the
  chips rather than guessed at. Filling them in is per-action work that the
  tests make safe.
