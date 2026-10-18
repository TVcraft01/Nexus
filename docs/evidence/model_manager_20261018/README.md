# Two models, one selection: the Model Manager

Date: 2026-10-18 · build: `flutter build linux --debug`, run from an isolated
`XDG_DATA_HOME` prepared with a finished profile · window 880×1000 on a dedicated
workspace, driven through `tool/ui_driver.py` (hyprctl, grim, tesseract,
`/dev/uinput`, wtype) · **the 1B was really downloaded and really run** on this
machine's llama.cpp (Vulkan backend)

The system actions needed a model that follows formatting rules. The 0.5B writes
`{"action":"set_flashlight","state":"on"}` most of the time; "most of the time"
is not a contract. So the app now ships a choice — the 469 MB model it always
had, and a 771 MB one that follows instructions — and this is the pass that put
both in front of a user, downloaded one of them on the wire, and let the bigger
one answer.

## The run

| # | Frame | What it shows |
|---|-------|---------------|
| 1 | `01-two-models.png` | Settings → BRAIN: **Qwen 2.5 0.5B** (469 MB · not downloaded, *"Fastest. Small enough to miss the action JSON now and then."*) and **Llama 3.2 1B** (771 MB · not downloaded, *"Bigger and smarter — better at following the action JSON."*), with the Download row below for the selected one |
| 2 | `02-llama-selected.png` | After tapping the 1B: the tick moved to it, and the row below became **Llama 3.2 1B — 771 MB. Runs here, no network, no account.** The preference written by that tap is on disk as `"flutter.on_device_model":"llama-3.2-1b"` |
| 3 | `03-selection-survives-restart.png` | The app killed and started again: still the 1B, still the 1B's download row. The selection is a preference, not a field |
| 4 | `04-downloading-the-1b.png` | Mid-download: **Downloading Llama 3.2 1B — 65% of 771 MB — keep Nexus open** |
| 5 | `05-1b-downloaded.png` | Finished: **Llama 3.2 1B — 771 MB on this device**, AI status back to *Answers on this device*, and the 0.5B row still *not downloaded* — the two files are independent |
| 6 | `06-1b-follows-the-json.png` | `it is dark in here` → **ⓘ I can't use the flashlight on Linux — Nexus does that on your phone.** The footer changed from *Your PC answers* to *This device answers — nothing here goes to a cloud*: the 1B parsed the request, the shell ran it, and the pill is the phone-only refusal the desktop backend gives |

The log of frame 5 and 6, in order:

```
LLM: fetching llama-3.2-1b-instruct-q4_k_m (771 MB)
LLM: llama-3.2-1b-instruct-q4_k_m 100%
LLM: llama-3.2-1b-instruct-q4_k_m cached (771 MB, hash ok)
LLM: Vulkan ready, ctx 2048, 4t
```

`hash ok` is the point of the pinned commit and the SHA-256 in `llm.dart`: the
bytes this app installs are the bytes that were checked, and a mirror that
changes under it fails the download rather than becoming the model.

## What changed

| file | what it is now |
| --- | --- |
| `lib/core/llm.dart` | `kLlamaModel`: Llama 3.2 1B Instruct Q4_K_M, 807,694,368 bytes, SHA-256 `3f5a2242…dcc1`, URL pinned to commit `b69aef11…aa401` of the Unsloth GGUF mirror |
| `lib/core/on_device_model.dart` | `OnDeviceModelChoice` (id, label, blurb, file name, weights) with `qwen` and `llama`; `ModelChoice`, a `ChangeNotifier` over a preferences store, with an `override` seam for tests; `OnDeviceModel` now names its file after the choice (Qwen keeps `model.gguf`, so an installed 469 MB is not downloaded twice) and gains `withChoice`, which is how the picker asks about a model that is not the selected one |
| `lib/core/on_device_ai_service.dart` | the brain follows the selection: `_current()` builds an `Llm` for whichever model is selected, disposes the previous engine when the choice changed — two sets of weights at once is 1.2 GB, which a phone answers by killing the app — and `delete()` only ever removes the selected file |
| `lib/main_ui.dart` | the picker: one row per model, ticked when selected, with its size and whether it is on the disk; selecting a model that is missing turns the row below into the Download row for *that* file; `main()` starts the preference read before the first frame so a restart answers with the picked model |

The signature change the task implied — "the service must load the file of the
selected model" — is why `OnDeviceAiService` no longer keeps one `Llm`: the shell
builds that service once for the life of the process, so a picker that only took
effect after a restart would be a picker that did nothing.

## What is covered by tests instead

- `test/model_choice_test.dart` — 10 tests: the two choices and their sizes, the
  1B's pinned URL/hash/size, id round trip and junk ids, the selection starting
  on the small model and surviving a restart, one notification per real change,
  each model reading/downloading/deleting *only its own file*, `withChoice`
  following the selection, the service looking for the selected file, and a
  caller-supplied engine being the one that is released.
- `test/main_ui_test.dart` — 3 more widget tests: the picker lists both models
  and switching moves the download row to the new one, the download writes the
  selected model's file name, and **Delete removes the selected model and leaves
  the other one on disk**.

## Not covered here

**The phone.** No device was on adb for this pass, so the 1B has not been run on
Android: its 771 MB file, the 1.2 GB peak the swap avoids, and how fast a 1B
answers on the A25 are all unmeasured. The download itself is the same
`Llm.download` the 0.5B used, and the swap is the same code path these tests
hold, but "runs on the phone" is a claim this evidence does not make.

**A runtime switch between two downloaded models.** The run downloaded the 1B
with the 0.5B absent, so the disposal path was exercised by code, not by a
second 469 MB download. Two files on disk, a tap between them, and the first
question after it is the check — and it is the one to run on the phone, where a
stray second engine matters most.
