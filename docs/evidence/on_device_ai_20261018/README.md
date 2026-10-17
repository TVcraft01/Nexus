# On-device AI: the model on the phone, and the PC as the fallback

Date: 2026-10-18 · build: `flutter build linux --debug` (the shell in
`lib/main_ui.dart`, the real app, driven through the real compositor)

This is the slice the seam was cut for. `LocalAiService.current` is now a
chain — `OnDeviceAiService` first, the PC's `OllamaService` second — and
Settings has a **Brain** section that reports which one will answer, downloads
the model, shows the download moving, and deletes it again.

## What was run

```
flutter build linux --debug
XDG_DATA_HOME=/tmp/nexus_brain_run/data ./build/linux/x64/debug/bundle/nexus
```

The window was placed on its own Hyprland workspace and driven with real
clicks and real keystrokes (`tool/ui_driver.py`: hyprctl geometry, grim
screenshots, tesseract OCR, `/dev/uinput`, `wtype`). Nothing in the app was
stubbed: this is the production binary, the real HuggingFace URL, the real
sha256, and llama.cpp through `llamadart`.

## 1. The Brain section, before any download

`01-brain-section-before.png`, read back at 2× (`02-brain-section-crop.png`):

```
BRAIN
AI status      Answers come from your PC over the local network. Works
               while you are on the same Wi-Fi.                PC (Ollama)
Download model Qwen2.5 0.5b q4 — 469 MB. Runs here, no network, no account  ›
```

The status is a *probe*, not a stored guess: `GET /api/tags` answered 200 on
this machine (`curl -o /dev/null -w '%{http_code}' localhost:11434/api/tags` →
`200`), so the row says `PC (Ollama)`. On a machine with no Ollama it says
`No AI available`, and with `model.gguf` present it says `On-Device (Loaded)`
without probing the PC at all.

## 2. The download, with the bar the user watches

Tapping **Download model** starts a real 469 MB fetch. OCR of the row, once per
poll (12–20 s apart):

```
Downloading Qwen2.5 0.5b q4        2% of 469 MB — keep Nexus open
                                   12%
                                   22%
                                   32%
                                   41%
                                   51%      ← 03-download-51-percent.png
                                   70%
                                   75%
                                   81%
                                   88%
                                   94%
```

and the app's own log, `LLM:` lines from `lib/core/llm.dart`:

```
LLM: fetching model (469 MB)
LLM: model 25%
LLM: model 50%
LLM: model 75%
LLM: model 100%
LLM: model cached (469 MB, hash ok)
```

The file only appears after its hash matches (`part.renameSync`), which is why
the row flips straight from progress to loaded — there is no state in which a
half model is on disk.

## 3. Loaded, and deletable

`04-model-loaded.png`:

```
BRAIN
AI status         On-Device (Loaded)
On-device model   Qwen2.5 0.5b q4 — 469 MB on this device   Downloaded
Delete model      Frees 469 MB. Answers come from your PC instead   ›
```

On Linux the documents directory is `$HOME/Documents`, so the run wrote
`~/Documents/model.gguf` (469 MB); on Android it is the app's own documents
directory, which is what the code asks `path_provider` for. The file was
deleted after the run — the button in this section is the way back.

## 4. A question, answered by this machine

`05-composer-note-on-device.png` — the line above the composer is no longer the
old promise (`Your PC answers — nothing here goes to a cloud.`); it reads the
same status the Settings row does:

```
This device answers — nothing here goes to a cloud.
```

Then a real question, typed and sent (`06-answer-from-on-device-model.png`):

```
In one sentence, what is a mesh network?
A mesh network connects devices without a central hub, using
wireless communication.
```

The log line that proves whose answer it was:

```
LLM: Vulkan ready, ctx 2048, 4t
```

— the on-device runtime loading the weights and generating, on this machine's
GPU, with no request leaving the box. The PC's Ollama was running throughout;
the chain never asked it, because the device answered first.

## What this run does not prove

- **The phone.** Same code paths, different platform: Android's documents
  directory, ARM inference speed, and the app's own memory ceiling are not
  exercised here.
- **Dark mode** — the Brain rows are read in light mode only.
- **A download that fails mid-flight on a real network** — that path is covered
  by `flutter test` against the test binding's refused socket and by the
  hash-mismatch test in `test/on_device_ai_service_test.dart`, not by pulling a
  cable out during a 469 MB fetch.
