# Nexus — voice layer

An Alexa-grade *experience* with none of Alexa's cloud: wake word, spoken
request, spoken answer, and it acts on the house. Local, offline, no vendor
account. This is a plan for a future sprint — no code, no new dependencies
today.

Design note, 2026-10-08. Existing seams it builds on: `lib/core/speech.dart`
(`SpeechInput` / `SpeechOutput`, live on Android), `lib/core/command_interpreter.dart`
(rules), `lib/core/tiny_brain.dart` (on-device model seam, honest null today).

## What is live now (2026-10-10)

The first slice shipped: **one verb, spoken, on the phone.** Tap the mic, say
"get report.pdf from my pc", and the file is fetched over the mesh.

| Step | Where it runs | Offline? |
|---|---|---|
| Mic → text | `MainActivity.startSpeech` (system `SpeechRecognizer`) | yes |
| Intent | `CommandInterpreter` (Dart, unchanged) | yes |
| Fetch | the mesh → the paired PC (Dart) | needs the peer, not the internet |
| Reply spoken | `MainActivity.speakText` (system `TextToSpeech`) | yes |

**No new dependency, and no `flutter_tts`.** Both halves are the platform's own
engines behind the two channels that were already in this tree
(`dev.nexus.nexus/speech`, `dev.nexus.nexus/speech_out`) — `MainActivity`
already had the recognizer and the `TextToSpeech` engine wired, so the work
here was the loop on top of them, not a new stack. A second TTS binding would
have been a second engine to initialise for the same words.

**Offline is chosen, not hoped for.** `startSpeech` asks
`SpeechRecognizer.isOnDeviceRecognitionAvailable` and — when the ROM has a
local model — uses `createOnDeviceSpeechRecognizer`, a recognizer with no
network path at all; otherwise the ordinary one with `EXTRA_PREFER_OFFLINE`.
Which one ran is logged, because the claim is about the device, not the code.

On the phone (2026-10-10), with the phrase played aloud by the PC's speakers
so the run went through a real microphone and a real room:

```
speech: listening on-device (no network)
speech: …What time is it
speech: heard "What time is it" (peak 10.0dB)
TextToSpeech: getHighestRankedPublicEngineName = com.google.android.tts
TextToSpeech: Connected to TTS engine
```

### Three things this pass learned

- **A recognizer writes what it heard, not what you meant.** "report.pdf"
  comes back as "report dot pdf", and the file-fetch grammar needs the
  extension to see a file at all. `spokenToWritten` in `lib/core/speech.dart`
  writes a spoken dot back as a dot — but only where a *filename* is ending
  (the end of the sentence, or the `from`/`to <device>` that follows it). Typed
  text never passes through it, so nothing anyone types can be rewritten.
- **A mis-hear is not an event.** Nothing heard now means the pill's ring goes
  out and the composer is idle again: no card, nothing said aloud. The old
  "I didn't catch that" reply turned every stray tap into a turn of
  conversation.
- **The microphone needs a way back.** The second tap on the mic — or the
  screen going away — calls `stop`: the pending listen answers null and the
  recognizer is released. Before this, a recognizer that never heard its own
  end-of-speech left the composer listening with no way out but leaving the
  screen.

### What this slice is not

Still pass 2 and 3: the wake word and the local LLM. It is English (whatever
language the device's recognizer has), one utterance at a time, and the state
machine is two states — idle and listening — because those are the two the app
can evidence. The ring is the only live feedback: no partial transcript is
rendered, though the engine's partials are logged for a device run.

## 1. Wake word

Always-on, streaming, offline. Pick one and train it on "hey nexus".

| Option | License | Model size | CPU (phone) | Offline | Vendor account |
|---|---|---|---|---|---|
| **openWakeWord** | Apache-2.0 | ~0.2–1 MB (ONNX/TFLite) | 1 core, low single-digit % | yes | none |
| Porcupine (Picovoice) | commercial; free personal only | ~100 KB | very low | yes | **requires AccessKey** |
| custom KWS (MicroWakeWord → TFLite) | Apache-2.0 | ~0.1–0.3 MB | low | yes | none |

**Recommend openWakeWord**, fallback a custom MicroWakeWord model trained on
"hey nexus". Porcupine is the best on paper and the only one that breaks the
no-vendor-account rule, so it is out unless that rule is waived. False-accept
is the thing to tune first: a wake word that fires on the TV is worse than none.

## 2. Speech-to-text

One utterance at a time, offline.

| Option | License | Model size | Latency (mid-range ARM) | Accuracy | Languages |
|---|---|---|---|---|---|
| **Android on-device STT** (`SpeechRecognizer`, `EXTRA_PREFER_OFFLINE`) | system/OEM | 0 (system) | lowest — streaming | good on-device | device-dependent |
| whisper.cpp `tiny` | MIT | ~31 MB (q5) | faster than real-time | fair | ~99 |
| whisper.cpp `base` | MIT | ~57 MB (q5) | ~1–2× real-time | good | ~99 |
| whisper.cpp `small` | MIT | ~181 MB (q5) | slower than real-time | very good | ~99 |
| Vosk small en | Apache-2.0 | ~40 MB | low, streaming | fair–good | many |

**Shipped: Android's on-device recognizer** (see "What is live now") — it was
already wired through `SpeechInput`, needs no new dependency, and is the
lowest-latency streaming option; `EXTRA_PREFER_OFFLINE` is set so it cannot
silently reach the cloud. Fallback **whisper.cpp `base` (q5)** when the ROM has no on-device model
or has no model for the language. Never `small`: it is slower than real-time on
this class of phone.

## 3. Intent

**Rules first, LLM fallback** — the boundary is the existing
`InterpretOutcome`, not a new classifier.

| Input | Handled by | Behaviour |
|---|---|---|
| `matched` | `CommandInterpreter` rules | act; unchanged |
| `needsInfo` / `ambiguous` | rules | ask the one question, unchanged |
| `unknown` | small local LLM | slot-fill the command grammar, else "I don't understand" |

The LLM's only job is to turn an unknown phrase into one of the *existing*
`ParsedCommand` actions (a tool call, not free text), so it can never invent a
capability. Model options:

| Option | Params | File (q4) | RAM floor | Fits 4–6 GB? |
|---|---|---|---|---|
| **Qwen2.5-0.5B-Instruct** | 0.5 B | ~0.4 GB | ~0.7–1 GB | comfortably |
| Qwen2.5-1.5B-Instruct | 1.5 B | ~1.0 GB | ~1.5–2 GB | yes, foreground only |
| Gemma-2B | 2 B | ~1.5 GB | ~2–2.5 GB | tight |
| Phi-3-mini | 3.8 B | ~2.3 GB | ~3 GB+ | risky — low-memory-killer |

**Recommend Qwen2.5-0.5B-Instruct** via llama.cpp behind the existing
`tiny_brain` channel, kept warm in the foreground service. Anything ≥2 B is a
foreground-only experiment; a 3.8 B model on a 4 GB phone will be killed while
you are talking to it. Open questions still go to the mesh/distributed brain,
exactly as today.

## 4. Text-to-speech

| Option | License | Voice size | Latency | Quality |
|---|---|---|---|---|
| **Android TTS** | system/OEM | 0 (system) | lowest | decent, varies by engine |
| Piper | MIT | ~20–60 MB/voice | near real-time on CPU | natural |
| Coqui TTS / XTTS | MPL-2.0 | large | GPU-oriented | excellent, but not this hardware |

**Shipped: Android TTS** (already wired in `MainActivity.speakText`), with
Piper as the quality upgrade if the system voice is not good enough. Piper needs
onnxruntime + an espeak-ng phonemizer step, so it is the larger change.

## 5. The loop, and where each step runs

```
wake ──► STT ──► intent ──► action ──► TTS
(Kotlin)  (Kotlin)  (Dart)     (Dart/mesh)  (Kotlin)
 always-on  per-utterance  rules→LLM  executor  speak
```

- **Wake + STT + TTS run in Kotlin**, in the existing foreground service:
  audio capture and playback belong to the platform side, beside the mic and
  speaker seams already there.
- **Intent + action run in Dart**, unchanged: the same `CommandInterpreter`
  and the same executor a typed question uses. Speech is just another ask —
  `SpeechInput` already routes recognized text through the typed pipeline.
- **Cached / kept warm**: wake model loaded once and never unloaded; STT model
  loaded on first utterance; LLM kept resident while the service is up; TTS
  engine initialised once. Model load is the latency, not the inference.
- **Network off**: the whole loop still works. Wake, STT, intent, action on
  local devices, and TTS are all on-device. Only the fallbacks that genuinely
  need the internet — weather, time zones, currency, web search — answer
  honestly that they are offline, exactly as they do today.

## 6. Non-goals

- **No cloud STT.** Audio is decoded on the phone, never uploaded.
- **No cloud LLM.** No inference leaves the device or the mesh.
- **No always-uploading audio.** The mic is local; nothing is streamed anywhere.
- **No vendor account.** No Picovoice key, no per-device licence server.

Plainly: **your voice never leaves the device.** Audio is processed in memory
and discarded the moment it becomes text; the only thing kept is the text you
actually acted on, in the same local log that already records typed asks — and
that log is yours to read and clear.
