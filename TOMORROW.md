# Tomorrow's Plan — Nexus v0.1.52

## Goal: One assistant living everywhere — every device you own answers as the same person, fully offline

---

## What just shipped (v0.1.52 milestone: "one assistant everywhere")

All green: 454 tests passing, analyzer clean, wired into the real app on both Linux and Android.

- **Conversation engine** (`lib/core/conversation_engine.dart`) — one owner of the assistant thread and the brain orchestration behind it; the teach flow survives every brain failure; concurrent conversations can't clobber each other.
- **Brain phases 1–5**:
  - Phase 1: conversational replies behind one seam (`lib/core/brain.dart`)
  - Phase 2: memory in the system prompt (`lib/core/conversation.dart`, query log)
  - Phase 3: the skill loop reorders what the user sees (`lib/core/skills.dart`)
  - Phase 4: voice in and out — mic on Android (`SpeechInput`), spoken replies via system TTS (`SpeechOutput`)
  - Phase 5: the distributed brain (`lib/core/distributed_brain.dart`) — tiny on-device model first, escalate over the mesh to a paired PC's brain (`brain.ask` / `brain.answer` protocol messages)
- **Cross-device sync**: facts, reminders, "which …?" defaults, and the user/assistant names propagate to every paired device.
- **Playtest suite**: `test/first_day_playtest_test.dart`, `test/assistant_playtest_test.dart`, `test/distributed_brain_test.dart` — real sockets, real pairing, the only fakes are the models.

## What's still stubbed

- **On-device tiny brain**: `TinyBrain` and the `dev.nexus.nexus/tiny_brain` channel answer honestly with null — real inference (llama.cpp / MediaPipe LLM) plugs in later. Until then a phone without a PC escalates honestly and is still a full assistant.

---

## Next up

### 1. Mesh-wide memory: ask on any device what you told another

**Current state:** facts sync as messages, but each device's conversation memory and query log are local.

**Target:** "What did I tell my phone yesterday?" answered on the PC, from the phone's memory.

**How:**
- Extend the mesh protocol with a `memory.ask` / `memory.answer` pair (like `brain.ask`), where a device requests the matching entries from a peer's query log and merges them into its prompt.
- Respect the same honesty rule as the brain: only devices with their own log serve; a served ask must never re-ask.

**Files to change:**
- `lib/core/protocol.dart` — `memory.ask` / `memory.answer` message types
- `lib/mesh/mesh_service.dart` — request/respond plumbing (mirror `requestBrainAnswer`)
- `lib/core/distributed_brain.dart` or a new `lib/core/mesh_memory.dart` — merge peer memory into the prompt
- `test/distributed_brain_test.dart` or a new playtest — two real devices, memory round-trip

### 2. Real on-device tiny brain (Android)

**Current state:** `TinyBrain.ask` always escalates because the platform side has no model.

**Target:** everyday questions answered on the phone itself, offline, no cloud.

**How:**
- Evaluate llama.cpp (`llama.android`) or MediaPipe LLM Inference as the in-app engine; download a ~1–3 GB model on first use (user-consented), keep it on-device.
- The `dev.nexus.nexus/tiny_brain` channel returns text + confidence; the distributed brain already handles low confidence by escalating.

**Files to change:**
- `android/app/src/main/kotlin/dev/nexus/nexus/MainActivity.kt` — implement `modelName` / `ask`
- `lib/core/tiny_brain.dart` — keep as-is (the seam already exists)
- `lib/ui/settings_view.dart` — model install/remove UI

### 3. Release v0.1.52

- Tag `v0.1.52` after the milestone is committed
- CI builds APK + Linux binary
- Update install script if needed

## Execution Order

1. **First:** Mesh-wide memory (visible, finishes the "one assistant" story)
2. **Second:** Release v0.1.52
3. **Third:** On-device tiny brain (big lift, independent of everything else)

## Version

- `lib/core/version.dart` → already `0.1.52`
- `pubspec.yaml` → already `0.1.52+152`