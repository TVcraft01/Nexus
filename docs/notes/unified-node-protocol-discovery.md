# Unified Node Protocol — discovery report

**Status:** Phase 1 discovery plus the approved Phase 2 capability clause only; no Phase 3 routing/consolidation. Phase 2 committed as `25ce3cf` (`feat(mesh): announce probed capabilities with provenance`).
**Base:** `main` at `c681808` after the separate capability-default commit; prior orientation and integration work was already uncommitted and remains outside the Phase 2 commit.
**Date:** 2026-10-26.

The question this answers: *should* "Unified Node Protocol" mean one wire format all
three subsystems speak (a), or one logical protocol — message types, auth, approval,
errors, capabilities — that different transports implement (b)? My read of the tree
says **(b)**, and for two of the three subsystems (a) is not merely unattractive but
impossible. §4 argues it from the code.

---

## 1. File inventory

### Git state

```
HEAD  c681808c75f696adcc386c99e68ef5384137de87   branch main
```

`git status --short` (full, including this report):

```
 M README.md
 M lib/main_ui.dart
 M lib/ui/home_tab.dart
 M lib/ui/privacy_policy_view.dart
 M lib/ui/settings_tab.dart
 M linux/runner/my_application.cc
 M pubspec.lock
 M pubspec.yaml
 M test/main_ui_test.dart
 M test/release_surface_test.dart
?? docs/notes/unified-node-protocol-discovery.md
?? lib/core/server_explorer.dart
?? lib/core/server_playbooks.dart
?? lib/core/ssh_service.dart
?? lib/ui/server_agent_page.dart
?? test/server_agent_test.dart
?? tmp_device/v1_a.png
?? tmp_device/v1_about.png
?? tmp_device/v1_after_onb.png
?? tmp_device/v1_ai_reply.png
?? tmp_device/v1_ai_reply2.png
?? tmp_device/v1_ai_reply3.png
?? tmp_device/v1_ans.png
?? tmp_device/v1_first_launch.png
?? tmp_device/v1_home.png
?? tmp_device/v1_main.png
?? tmp_device/v1_msg.png
?? tmp_device/v1_reply.png
?? tmp_device/v1_reply2.png
?? tmp_device/v1_rotation_landscape.png
?? tmp_device/v1_rotation_portrait.png
?? tmp_device/v1_s3.png
?? tmp_device/v1_s3b.png
?? tmp_device/v1_sel.png
?? tmp_device/v1_sel2.png
?? tmp_device/v1_state.png
?? tmp_device/v1_typed.png
```

The inventory above was recorded before Phase 2. At implementation start, the branch was
`main` at `c681808c75f696adcc386c99e68ef5384137de87`; the Phase 2 commit touched these paths:

- `lib/core/capability_probe.dart` (new)
- `lib/core/agent_contract.dart`
- `lib/core/protocol.dart`
- `lib/core/resource_map.dart`
- `lib/mesh/mesh_service.dart`
- `lib/ui/assistant_view.dart`
- `lib/ui/devices_view.dart`
- `android/app/src/main/kotlin/dev/nexus/nexus/MainActivity.kt`
- `test/capability_probe_test.dart` (new)
- `test/mesh_test.dart`
- `test/authenticated_presence_test.dart`
- `test/resource_map_test.dart`

No orientation-specific files were included. The full working tree still contains the
pre-existing orientation and other unrelated uncommitted work; the Phase 2 commit was
made from only the scoped files above, using staged hunks where those files also carried
unrelated formatting or earlier edits.

Only the orientation portions of `lib/main_ui.dart`, `lib/ui/home_tab.dart`, and
`test/main_ui_test.dart` belong to this pass. The rest is earlier, still-uncommitted
work — the v1.0 packaging pass and the Server Agent. No tracked files were renamed; `main_ui.dart` is the live shell and `home_tab.dart` is its `part`, not a git rename.

### New under `lib/` (not in HEAD)

| File | Lines | What it is |
|---|---|---|
| `lib/core/ssh_service.dart` | 213 | the SSH2 client: connect, one command at a time, streamed output |
| `lib/core/server_playbooks.dart` | 109 | the only shell text in the app: `setup_minecraft`, and the intent regex |
| `lib/core/server_explorer.dart` | 234 | read-only tour (7 probes) + AI summary + Memory Vault write |
| `lib/ui/server_agent_page.dart` | 774 | the page: login fields, playbook rows, approval dialog, live terminal |

### Renamed / split / superseded

- `lib/main_ui.dart` (7,406 lines) is the live shell. `lib/main_old.dart` is **still
  tracked** and referenced only by a comment in `lib/main.dart:16`. It is dead weight,
  not a rename waiting to land.
- `lib/ui/home_tab.dart` is not a library: it is `part of '../main_ui.dart'` (line 1).
  The Home screen was split out for review size, not for a module boundary.
- No `hive*`, `node*` or `moondream*` file exists. There is no Hive *file*: the Hive
  Router is `HiveRouter`, `HiveCompute` and `HiveNotice` inside
  `lib/core/local_ai_service.dart:336-668`.
- The source files matching the requested subsystem name families are:
  `lib/core/ml_vision_service.dart`, `lib/core/vision_ai.dart`,
  `lib/core/vision_ai_service.dart`, `lib/core/text_generation_backend.dart` (17 lines),
  plus the four newly added SSH/Server Agent files listed above. There are no files
  named `hive*`, `node*`, or `moondream*`; Hive Router is in `local_ai_service.dart`.
  No source-file rename is detected by git. No `lib/core/protocol.dart` or
  `lib/core/agent_contract.dart` diff exists against HEAD; both are tracked and
  their working-tree content is the current content quoted in §1. Their exact
  paths are `lib/core/protocol.dart` and `lib/core/agent_contract.dart`.

### The two documents the consolidation builds on

`lib/core/protocol.dart` (151 lines) — mesh wire format, current content:

```dart
class NexusMessage {
  final String type; final String from; final String? to;
  final Map<String, dynamic> payload; final String id; final int ts;
  // 30+ type constants, e.g.
  static const ping = 'ping';                     static const pong = 'pong';
  static const pairRequest = 'pair-request';      static const pairAccept = 'pair-accept';
  static const clipboard = 'clipboard';           static const fileFetch = 'file.get';
  static const agentAction = 'agent.action';      static const agentResult = 'agent.result';
  static const brainAsk = 'brain.ask';            static const brainAnswer = 'brain.answer';
  Map<String, dynamic> toJson() => {'type','from',?'to','payload','id','ts'};
  String encodePlain() => jsonEncode(toJson());
}

class FrameDecoder {                 // protocol.dart:97-141
  static const int maxFrameBytes = 1 << 20;   // 1 MiB guard
  // 4-byte big-endian length prefix, then that many bytes of UTF-8 JSON
  static Uint8List encodeFrame(List<int> payload);
}
```

`lib/core/agent_contract.dart` (763 lines) — the action vocabulary, at declaration
level (full file in the tree):

```
AgentActions                    :6    29 action ids: device.list, led.blink, comm.call,
                                     comm.message, media.play, alarm.set, … clipboard.write
AgentDeviceSnapshot             :340   {deviceId, name, platform, capabilities}
sealed AgentDispatch            :383   AgentDeviceList | AgentActionPlan | AgentMessage |
                                      AgentClarification
AgentAsks                       :444   whoToCall / whoToText / whoToEmail (one wording)
AgentDispatchResult             :472   {status, message, dispatch}
DeviceCapability                :503   (id, version=1)  + toJson/fromJson
DeviceCapabilities              :517   {deviceId, version, List<DeviceCapability>}
                                      bool supports(id, {version})
AgentApproval                   :533   {required, approved, denied}
AgentResultStatus               :535   {succeeded, required, denied, unavailable, needsInfo}
extension AgentResultStatusWording :541  label / isQuestion / isFailure / reportFrom / explain
AgentRequest                    :630   {version, requestId, target, action,
                                        arguments, approval}  + toJson/fromJson
                                      bool isAuthorized(DeviceCapabilities)
dispatchCommand(...)            :679   ParsedCommand → local result or checked request
```

---

## 2. Wire format per subsystem

### 2.1 Hive Router — HTTP/1.1 to Ollama on TCP 11434, no envelope

**Where.** `HiveRouter` is `lib/core/local_ai_service.dart:383`; the client it dials is
`OllamaService` (`lib/core/ollama_service.dart`). There is no mesh frame, no socket it
owns, no WebSocket.

**Request shapes** (`ollama_service.dart`):

| Call | Request | Line |
|---|---|---|
| liveness probe | `GET /api/tags`, 2 s timeout, never throws | `:201` |
| one question | `POST /api/generate` `{model, prompt, system, stream:false}` | `:242`, `:246` |
| with history | `POST /api/chat` `{model, messages:[{role,content}…], stream:false}` | `:246-262` |

`system` is `kNexusOllamaSystem` with the device clock and the Memory Vault appended at
request time (`LocalAiService.systemWithMemory`).

**Response shape.** One JSON object (no NDJSON: `stream:false` is deliberate, andit is why the "streaming" contract is a single piece — `ollama_service.dart:187`). Fields read:
`response` (`/api/generate`) or `message.content` (`/api/chat`) at `:310`; everything else
(`done_reason`, `eval_count`, `total_duration`, `context`) is ignored.

**Route selection** (`local_ai_service.dart`): the first paired device that looks like a
computer wins (`_pairedDesktop`, `:517`), preferring one whose pairing record says
`ollama: true`; the address is that device's first LAN IPv4 on port 11434
(`_serviceFor`, `:574`). Probe results are cached 10 s, and concurrent probes share one
`_inFlight` future (`:445-472`) — that dedupe exists because a chip and a composer read
in the same second disagreed once.

**Error vocabulary.** One exception class with three pinned sentences
(`ollama_service.dart:96-110`): unreachable (`kNexusOllamaUnreachableText`), HTTP status
plus `ollama pull <model>`, and "answered with nothing". Two route events:
`HiveNotice.pcConnectedWeakModel` and `HiveNotice.pcDisconnected`, plus the live
`HiveCompute{onDevice, pc}` (`local_ai_service.dart:336-372`).

**Live exchange through HiveRouter, captured on this PC** (local Ollama, model
`llama3.2:latest`, 3.2B Q4_K_M). The probe reached `GET /api/tags` with HTTP 200, then
HiveRouter selected its paired desktop, used its real `OllamaService`, and sent:

```
POST /api/generate
{"model":"llama3.2","prompt":"Reply with exactly: live Hive Router exchange succeeded.",
 "system":"You are Nexus. Answer in one short sentence.","stream":false}

HTTP 200 after 10,597 ms
"Live Hive Router exchange succeeded."
```

The router's configured route was `http://127.0.0.1:11434`; the paired desktop record
was injected as a local candidate and its reachability probe called `OllamaService`.
This exercised the actual HiveRouter → OllamaService → local Ollama HTTP path, not just
the Ollama endpoint directly.

**Error path, captured against an Ollama-shaped loopback mock:** a second HiveRouter
instance used a local `HttpServer` that returned HTTP 503 for its generation. It sent
`POST /api/generate` with prompt `phase1 error probe`; OllamaService surfaced its pinned
HTTP-status exception, HiveRouter emitted the fallback path, and the local brain returned
`device fallback`. This exercised the router's request/error/fallback behavior without
relying on taking the real model offline.

A prior direct `/api/generate` and `/api/chat` smoke sample against Ollama is retained
below as endpoint reference, but it is not the evidence for the HiveRouter verdict.

```
POST /api/generate
{"model":"llama3.2",
 "prompt":"In one short sentence, what runs on this machine?",
 "system":"You are Nexus, a private assistant. Answer in two or three short sentences.",
 "stream":false}

HTTP 200 in 20.48 s
{"model":"llama3.2:latest","created_at":"…","response":"Most machines run on a variety of
 operating systems, including Windows, macOS, Linux, and mobile devices, depending on the
 specific device and software requirements.","done":true,"done_reason":"stop",
 "context":[…],"total_duration":…,"load_duration":…,"prompt_eval_count":…,
 "prompt_eval_cached_count":…,"prompt_eval_duration":…,"eval_count":31,"eval_durations":…}
```

```
POST /api/chat
{"model":"llama3.2","messages":[
  {"role":"system","content":"You are Nexus, a private assistant."},
  {"role":"user","content":"what is a LAN?"},
  {"role":"assistant","content":"A local network in one building."},
  {"role":"user","content":"and a mesh?"}],"stream":false}

HTTP 200 in 5.45 s
{"message":{"role":"assistant","content":"In the context of networking, a mesh network is a
 type of network topology where each device … is connected directly to every other device.
 This creates a web-like structure, where data can travel through multiple paths …"},
 "done_reason":"stop","eval_count":…}
```

Two things this exchange makes concrete: the 20 s cold call is model load, not the
network, so any node-protocol timeout shorter than ~30 s would call a healthy PC dead;
and the answer is prose with no structure to validate — a node protocol cannot lean on
the model's output for routing decisions.

**Authentication:** none. The gate is "the pairing record names this address", and the
PC's Ollama accepts any caller on the LAN. There is no app-level auth tag, no TLS.

### 2.2 SSH Server Agent — SSH2 exec channels, one command per channel

**Where.** `lib/core/ssh_service.dart` (transport), `lib/core/server_playbooks.dart`
(the only commands), `lib/ui/server_agent_page.dart` (approval + terminal).

**Message shape.** There is no application envelope at all. The unit is
`Stream<SshOutput> run(String command)` (`ssh_service.dart:150`), where `SshOutput` is
`SshLine(text)` … then exactly one `SshExit(code)`; `SshFailure(message)` is thrown for
anything worth a sentence (unreachable, timeout, refused login, command refused).
Connections are password-only (`onPasswordRequest`), one `SSHClient` reused for every
command in a playbook (`_connected`, `:102`), each command in its own session with a
pty 200×50 so stderr and stdout interleave in the order the far end wrote them.

**Approval flow, end to end** (`server_agent_page.dart`):

1. The sentence is matched by regex, not a model: `playbookForIntent` (`:103`) requires
   a `minecraft` word plus a server word or an intent verb.
2. `_startPlaybook` (`:202`) reads the login fields into an `SshTarget`. **No connection
   is opened before the dialog.**
3. `_confirm` (`:290`) shows `playbook.commands.join('\n\n')` verbatim in a monospace
   box, the playbook's own description (including "Accepts the Minecraft EULA on your
   behalf"), and a red `Execute on Server` (`kNexusServerExecute`, `:376`) returning
   `bool`.
4. On `true`, the commands run in order and the run aborts on the first non-zero exit.
   On `false` or a dismissed dialog, nothing is constructed and no socket is opened.

**What the far end receives on approve** — exactly these five strings
(`server_playbooks.dart:47-73`), one exec channel each:

```
command -v docker >/dev/null 2>&1 || (curl -fsSL https://get.docker.com | sudo -n sh)
sudo -n docker pull itzg/minecraft-server:latest
sudo -n docker rm -f nexus-minecraft >/dev/null 2>&1 || true
sudo -n docker run -d --name nexus-minecraft --restart unless-stopped -p 25565:25565 \
  -e EULA=TRUE -e MEMORY=2G -v nexus-minecraft-data:/data itzg/minecraft-server:latest
sudo -n docker ps --filter name=nexus-minecraft --format "{{.Status}}"
```

On deny: **nothing**. That is the strongest property this subsystem has and the thing a
protocol change must not weaken: the approved object is a `Playbook` id, and there is no
code path from model text to a shell string.

**Error vocabulary:** `SshFailure` (a string), the page's `_status` sentence, and the
terminal's `exit N — stopped here.` (`:245-248`). No enum, no typed reason.

**Exercised on this PC with a local simulated far end.** The ServerAgentPage was driven
through the actual user flow: enter a loopback-labelled target, request Minecraft setup,
inspect the confirmation, approve, then capture the fake runner's calls and replies. This
runs the approval and dispatch/UI path through `SshRunner`; it does not claim an SSH2
handshake or a real OpenSSH far end (nothing listens on port 22, and no credentials for a
real host were supplied). Captured exchange:

```
UI target: local-sim@127.0.0.1:2222
user request: "make a minecraft server"
user approval: Execute on Server
exec 1: command -v docker >/dev/null 2>&1 || (curl -fsSL https://get.docker.com | sudo -n sh)
  -> mock: docker already installed; exit=0
exec 2: sudo -n docker pull itzg/minecraft-server:latest
  -> mock: command accepted; exit=0
exec 3: sudo -n docker rm -f nexus-minecraft >/dev/null 2>&1 || true
  -> mock: command accepted; exit=0
exec 4: sudo -n docker run -d --name nexus-minecraft --restart unless-stopped -p 25565:25565 -e EULA=TRUE -e MEMORY=2G -v nexus-minecraft-data:/data itzg/minecraft-server:latest
  -> mock: command accepted; exit=0
exec 5: sudo -n docker ps --filter name=nexus-minecraft --format "{{.Status}}"
  -> mock: container Up 3 seconds; exit=0
UI result: Minecraft server is running
```

The existing cancel test is the deny exchange: the page opens no runner, so the far end
receives no command.

### 2.3 Mesh — framed JSON over TCP, encrypted envelope

**Framing.** `protocol.dart:99-141`: 4-byte big-endian length, then UTF-8 JSON, 1 MiB
guard. **Envelope.** Plain frames for presence; everything sensitive is
`{"enc": "<base64 iv||ciphertext||mac>"}` (`protocol.dart:113`).

**Send path — confirmed still the path on this tree** (`mesh_service.dart`):

```
_sendEnc(peer, msg)                 :3397
  key  = _sessionKeyFor(peer)       :1586  → deriveSessionKey (crypto.dart:51), cached
  enc  = encryptToB64(jsonEncode(msg.toJson()), key)   crypto.dart:107
  frame= FrameDecoder.encodeFrame(encodeJson({'enc': enc}))
  write to: cached outbound socket → inbound tunnel socket (cable) → dial (:1484)
```

**Receive path.** `FrameDecoder` → `_handleEncFrame` (`:1338`) which identifies the peer
by socket, else by trying every paired key (`_identifySender`), else treats the frame as a
pairing handshake; a frame that will not decrypt is dropped, never trusted. The identity
passed downstream is the `provenId` the key proved, never the `from` in the payload
(`_handleMessage`, `:1602`).

**Request/response correlation.** Ids plus completers: `requestBrainAnswer` registers
`_pendingBrainResults[requestId]` **before** sending (`:640`) and times out at 30 s;
`sendAgentRequest` does the same for `agent.action` at 15 s; `_recentMessageIds` dedupes
relayed frames.

**Presence** is plaintext on purpose (a stranger must be able to announce itself) but
carries `presenceTag` — an HMAC over `kind|from|id|ts` (`crypto.dart:80`) — so only a tag
that verifies may move `_verified`.

**Diff vs `main`:** `protocol.dart` adds only the `caps` payload-key constant; the frame
length prefix, JSON envelope, and `FrameDecoder` are unchanged. `mesh_service.dart` adds
capability probe/announcement state and the proven-brain gate; the existing framing and
`_sendEnc` encrypted send path are unchanged. Nothing in Hive or SSH writes to the mesh.

---

## 3. Shared primitives already present

| Primitive | Mesh | Hive | SSH | Verdict |
|---|---|---|---|---|
| **Auth** | HKDF-SHA256 per-pair session key + AES-GCM (`crypto.dart:51,107`); HMAC presence tag (`:80`) | none — the paired address is the gate, Ollama has no auth | the server's own login, password held in memory for the page's lifetime | Only Mesh has app-level auth. Nothing to inherit for the other two. |
| **Approval gate** | `AgentApproval{required,approved,denied}` + `AgentRequest.isAuthorized` (`agent_contract.dart:533,668`) — the only *serialized* approval | none (inference is read-only) | UI dialog returning `bool` over an immutable `Playbook` (`server_agent_page.dart:290`) | Mesh is the only typed gate, and SSH deliberately does not use it (the far end cannot echo a state back). |
| **Error vocabulary** | `lastFileError` strings + `AgentResultStatus` with `label`/`explain`/`reportFrom` | `OllamaException` (3 sentences) + `HiveNotice` | `SshFailure` string + page status | `FileFetchWords` (`answers.dart:906`) is the only typed sentence family, and it serves one vertical. No shared base. |
| **Capability declaration** | `DeviceCapabilities{deviceId, version, [{id, version}]}` from `defaultCapabilitiesFor(platform)` (`capability.dart:639-653`), checked by `isAuthorized` | one unversioned boolean: `ollama: true` in the pairing invite (`pair_invite.dart:108,187`) stored as `PairedDevice.ollama` (`paired_devices.dart:103`), then the router probes live | none — discovered by running commands (`server_explorer.dart`) | The typed versioned list is the strongest existing model. Hive's boolean is the one that should become a capability. |
| **State ownership** | `_verified` (proof) vs `_lastSeen` (any announcement) — `mesh_service.dart:308-309`, documented at `mesh_transport.dart:29-36` | `_checkedAt` / `_online` / `_target` + `_inFlight` (`local_ai_service.dart:476-500`) | page `_running`/`_exploring`; `SshService._client` cached per runner; no liveness at all | Every subsystem has the same bug class in a different costume (below). |

**The stale-state equivalent in each:**

- **Mesh** — `_lastSeen` advances when *we* send. A link built on it would never notice a
  silent drop. The fix was to make the transport report `lastHeardAt` (proof) and let the
  supervisor decide. `MeshTransport` exists because of exactly this.
- **Hive** — the cached probe. `_checkedAt`/`_online` said "PC" while a composer built
  from a different read said "device"; the fix was registering `_inFlight` so the second
  caller waits for the first answer (`local_ai_service.dart:445-472`). The same shape:
  a cached opinion outliving the fact it described.
- **SSH** — the cached `SSHClient`. A playback that starts after a Wi-Fi change will fail
  on its first command with a transport error (honest, but mid-run), and `_status` is the
  page's memory of the last attempt — which is why `_startPlaybook` clears it before the
  dialog. There is no heartbeat: the equivalent of `_verified` does not exist here, and a
  node protocol that wants one has to say what "alive" means for an exec channel.

### How each subsystem decides what a device can do — and who it trusts

**Mesh** has two capability sources. Local concrete hardware/services are found by
`RealCapabilityProbe` (`capability_probe.dart:15-112`); the app action vocabulary is still
static `defaultCapabilitiesFor(platform)` (`capability.dart:639-653`). The announcement is
the union of those sets in ping/pong (`mesh_service.dart:652-675, 1800-1860, 3620-3650`).
Peer `caps` is persisted with an announcement bit and provenance (`mesh_service.dart:61-126,
701-736`); `ResourceMap` consumes announcements verbatim, falls back to defaults only for
legacy peers, and marks that fallback assumed (`resource_map.dart:208-246`). A remote
action still separately requires target match, `AgentApproval.approved`, and support in
the target's versioned `DeviceCapabilities` (`AgentRequest.isAuthorized`,
`agent_contract.dart:630-672`). Previously `_notePeerBrain(msg.from, payload['brain'] == true)`
ran on paired-ID ping/pong without checking `proven`; it now runs only if `proven` is true
(`mesh_service.dart:1740-1860`). Thus a plaintext `brain:true` is no longer a delegation
claim the app acts on. Proven means authenticated sender, not proof the hardware functions.

**Hive** chooses a paired desktop using pairing plus a platform/name heuristic
(`local_ai_service.dart:517-565`), prefers the `ollama` pairing-time boolean in the QR and
stored `PairedDevice` (`pair_invite.dart:98-108,163,185-206`; `paired_devices.dart:25-38,
97-103,167-182`), then probes Ollama `/api/tags` over HTTP (`ollama_service.dart:194-211`)
before using it. The live probe establishes an HTTP service answers, not an authenticated
node identity or actual device ownership of the address. The QR `ollama` bit is an
unproven feature hint used for preference, not final authority. Hive has no shared
`proven`/`assumed` state.

**SSH Server Agent** makes no remote capability claim. The app offers actions from its
local closed playbook list and parser (`server_playbooks.dart:46-75,100-109`); its
read-only explorer runs a fixed probe list (`server_explorer.dart:40-61,150-177`). User
supplies host/login; UI presents exact commands before consent (`server_agent_page.dart:
202-232,290-380`). Approve proceeds to SSH password authentication and server-side command
execution (`ssh_service.dart:91-146`); deny invokes no runner. There is no app node identity,
challenge, or hardware declaration. Its `SshRunner` fake is testability, not evidence about
a real host.


**Phase 2 capability clause (implemented in this pass):** `CapabilityProbe.probe()` is
called lazily on the first startup presence exchange and cached for the mesh instance;
there are no permission prompts, network calls, or model probing. Android's native
probe checks camera, mic, app-private filesystem access, display dimensions, battery
service, torch, contacts provider visibility, USB host, speech-recognition service,
audio output devices, and visible TTS services. Linux checks filesystem, display,
serial-device nodes, and `ssh`/`ollama` executables. Each failed check is absent; an
unknown platform returns an empty hardware-probe set. Mesh unions these results with the
static action ids from `defaultCapabilitiesFor` for known platforms, then sends the
sorted, deduplicated `payload['caps']` list in every presence ping/pong. This is a
permission-free availability snapshot, not a runtime usability check or hardware
attestation.

On receive, a session-key-proven ping/pong stores the list as `verified`; an unproven
paired-ID frame stores it as `assumed`. Missing `caps` leaves the peer unannounced; an
explicit empty `caps: []` records authoritative absence and suppresses fallback.
`ResourceMap` uses announced values verbatim; only a legacy peer that has never announced
falls back to platform defaults, marked `assumed`. Lists, announcement state, and
provenance survive restart. Monotonicity is enforced: after a verified announcement,
a later unproven frame cannot replace or downgrade the list, even if it has fewer caps
or an empty list. Brain delegation shares the `proven` gate, so plaintext `brain:true`
cannot make a peer delegable. Static platform action ids remain claims based on the local
executor registry; evidence still means authenticated source, not that an action or
sensor works. Later protocol work can refine staleness/refresh semantics without
changing this wire meaning.

**Narrow seams already in the family** (the pattern a unified protocol should copy, not
invent): `MeshTransport` (`mesh_transport.dart:54-83`), `FileFetchMesh`
(`file_fetch.dart:36`), `SshRunner` (`ssh_service.dart:74-88`),
`TextGenerationBackend` (`text_generation_backend.dart`), and `LocalAiService`
(`local_ai_service.dart:112`). Each is a small interface the core owns and a transport
adapts itself to.

---

## 4. One-page proposal for review

**Recommendation: (b), one logical protocol over several transports.**

Hive and SSH were read, not exercised. The recommendation may change after a live exchange.

**Phase 2 capability clause:** capability identity and evidence should be logical protocol
concepts shared across transports; the transport carries the claim but does not decide its
meaning. Mesh's ping/pong now carries sorted `caps`, with `assumed` for an unproven paired
claim and `verified` for a session-key-proven announcement. Missing/empty means no known
capabilities, never a platform guess, except legacy records which remain explicitly assumed.
For other transports, define equivalent provenance in their own exchange: Hive's HTTP
probe can establish endpoint reachability but not node identity; SSH's login establishes
server-authenticated access but not hardware attestation. Do not label either as Mesh-style
verified unless identity is cryptographically bound to the claimed node.

### Why (a) is out

(a) says Hive, SSH and Mesh speak one wire format. Two of the three cannot:

- **SSH's far end is OpenSSH.** We do not own both ends of that socket. There is no place
  to put a 4-byte length prefix, an AES-GCM envelope, or a `NexusMessage`; the server
  receives `exec "<command>"` and is entitled to nothing else. A "unified frame" here
  would have to be an opaque payload inside the command line, which is precisely the
  model-writes-shell path this feature exists to prevent.
- **Hive's far end is Ollama.** A third-party HTTP API with a fixed JSON schema and no
  auth. We can wrap it (a Nexus sidecar on the PC), but that is a new program to install —
  a different product decision, not a refactor.

Only the mesh owns both ends. (a) would therefore unify one subsystem with itself and
leave two adapters pretending.

### Why (b) fits the tree

- **Two of three are already request/response.** Hive is one HTTP call, one JSON body,
  one answer — and it is *not* a stream on the wire (`stream:false`, by choice). SSH is one
  exec channel, a burst of lines, one exit code. That is the same shape: ask → answer(s) →
  terminal event. Only the Mesh is genuinely asynchronous: unsolicited presence, clipboard
  pushes, `agent.learned` broadcasts, ids with completers and dedupe.
- **The tree already has the seam pattern.** `MeshTransport`, `FileFetchMesh`,
  `SshRunner`, `TextGenerationBackend`: four examples of "core owns a small interface, a
  transport adapts itself". A unified protocol that adds a `BrainTransport` and reuses
  `SshRunner` is one more of these, not a new architecture.
- **The vocabulary mostly exists.** `AgentRequest` / `AgentResultStatus` /
  `DeviceCapabilities` / `AgentApproval` are typed, versioned and already tested. The
  pieces that are *not* unified are exactly the ones that are transport-specific today.

### What "unified" should mean, concretely

1. **One message vocabulary.** `AgentRequest` stays the unit of work; add the two
   requests the tree can already perform but has no shared spelling for:
   `brain.ask` (mesh) ↔ `/api/generate` (hive) ↔ a future remote executor (ssh). One
   request id, one 15/30 s timeout story, one correlation rule (register before send).
2. **One approval model.** `AgentApproval{required,approved,denied}` wherever it can be
   carried. Mesh carries it in the request. SSH carries it only in the UI — the far end
   cannot echo a state — so approval is a property of the node, not the transport. A
   transport that cannot carry one may present it locally but must not claim it on wire.
3. **One error vocabulary.** `AgentResultStatus` stays the five outcomes; add the
   `NodeError` sentence family modelled on `FileFetchWords` (`answers.dart:906`) so
   "unreachable", "refused", "not installed", "answered with nothing" are one set of
   sentences instead of three dialects (`kNexusOllamaUnreachableText`, `SshFailure`,
   `lastFileError`).
4. **One capability declaration, with provenance.** The Phase 2 clause above: local
   startup probes publish canonical `caps` on ping/pong. Three states matter: a legacy peer
   that has never announced uses platform fallback as `assumed`; explicit empty `caps: []`
   means no capabilities; non-empty claims are `assumed` until the frame is proven, then
   `verified`. Unproven frames cannot overwrite verified state. The typed
   `DeviceCapabilities`/`supports()` remains the action vocabulary. Capability proof means
   authenticated source, not sensor attestation.
   Hive's `ollama` QR field is migration-only and cannot independently establish a
   verified capability; SSH playbooks remain local policy, not remote self-claims.
5. **Keep apart, deliberately:** pairing secrets and the presence HMAC (mesh-only), the
   Ollama HTTP shape (third-party), SSH exec semantics (OpenSSH), and each transport's
   own framing limits (mesh 1 MiB JSON frames; weather-sized HTTP bodies; pty line
   streams).

### Risks and open questions for the review

- **The asymmetry that must stay documented:** SSH cannot carry an in-band approval or
  auth tag, so a "unified" protocol whose type system assumes either will lie about SSH.
- **The discovered mesh trust gap (closed in Phase 2):** ping/pong brain claims now update
  state only when `proven` is true; capability provenance follows the same proof boundary.
  Keep this gate when protocol state moves or gets refactored.
- **Hive has no auth at all.** Unifying its capability/error vocabularies without adding
  auth would make the family look safer than it is. If any of the three should grow app
  auth first, it is the one that sends prompts to a machine on the LAN.
- **The models are small.** A 0.5B model cannot be trusted to format a protocol message;
  every routing decision in this report is already code (`playbookForIntent`,
  `_pairedDesktop`), and that must stay true — the protocol is for nodes, not for prompts.
- **`main_old.dart`** is a live trap for this work: it is a second shell with its own
  assumptions, still tracked. Delete or quarantine it before a protocol change touches
  the shell again.**Bottom line:** (b) remains the working proposal, not a decision: one
vocabulary, one capability-evidence model, one approval meaning, over Mesh frames, Hive HTTP and SSH exec,
each behind its existing narrow seam. Hive and SSH were read, not exercised. The
recommendation may change after a live exchange. Do not implement the consolidation until
that design decision is reviewed.

## Phase 2 verification record

- Full Flutter suite after the final code edits: **1709 passed, 3 skipped**; no failures (`flutter test --no-pub --reporter compact`).
- Focused capability probe, ResourceMap, Mesh and authenticated-presence suites passed; the explicit monotonicity test proves verified evidence survives a later unproven, narrower announcement.
- Analyzer: **60 informational issues and no errors** (`flutter analyze --no-pub`); Flutter exits with status 1 because this project treats informational lints as a non-zero result.
- Ollama is available at `127.0.0.1:11434` (`llama3.2:latest`). A prior live loopback two-node Mesh run paired successfully, received proven `brain:true` presence, delegated a prompt through the encrypted mesh request, and got `mesh-live-ok` back. A direct `/api/generate` probe timed out; the tested product path was `/api/chat` via `LocalBrain`.
- Brain delegation trust gate: **gated**, test: [`test/authenticated_presence_test.dart`](../../test/authenticated_presence_test.dart) — `a stranger cannot set brain:true in a plaintext ping`.
- `adb devices -l` listed no attached devices. Phone-side capability announcement was not verified on-device.
- Android native probing uses package visibility for TTS services and contacts-provider availability; camera/mic, storage access, torch and USB are checked without requesting runtime permission. A phone run remains useful to validate actual OEM behavior.

The Phase 2 commit contains only capability-clause changes. No Phase 3 routing, consolidation, or `ResourceMap.choose()` callers were started. Earlier unrelated changes remain uncommitted.

**PR body:**

> Capability evidence uses three states: legacy peer, never announced → platform fallback marked ASSUMED; peer announced empty caps → no capabilities; peer announced non-empty caps → those capabilities, ASSUMED while unproven or VERIFIED when proven. Unproven frames never downgrade verified evidence.
>
> SSH approval flow exercised through simulated runner; SSH2 handshake not exercised against a real SSH host. Phase 3 SSH changes must pass through the simulated runner test as load-bearing.
