# Memory: the thread survives a relaunch, and the answer knows what was said

Date: 2026-10-18 · build: `flutter build apk --release` (0.4.0, versionCode
157), installed over adb at 11:26 · device: SM-A256E (a25x), Android 16,
1080×2340 · answers from **the phone's own Qwen2.5 0.5B**, no PC on the network

Until this slice the shell had two halves that each forgot: the thread was a
`State` field, so `am force-stop` emptied it, and `generateResponseStream` was
handed the newest sentence alone, so "what is my name" reached the model as a
question about nothing. Both are fixed here, and both were driven on the phone.

## The run

```
flutter build apk --release && adb install -r build/app/outputs/flutter-apk/app-release.apk
# frames 1–2: type two exchanges, ask a question that only makes sense with one
adb shell am force-stop dev.nexus.nexus      # the process is gone, not backgrounded
# frame 3: launch again — the same thread, in the same order
# frames 4–6: Settings → CHAT → Clear chat → the red dialog → the welcome screen
```

| # | Frame | What it shows |
|---|-------|---------------|
| 1 | `01-context-earlier-turn.png` | A two-turn exchange (`remember that my favourite colour is green` → *"I'm glad you like the color green!"*) over the question `what is my favourite colour` |
| 2 | `02-context-answered-with-name.png` | `my name is Sam` → *"Hello Sam!"*, then `what is my name` → **"Your name is Sam. How may I assist you today?"** — the earlier turn arrived |
| 3 | `03-relaunch-thread-restored.png` | After `am force-stop` and a cold launch: the same four bubbles, same order, no placeholder left behind |
| 4 | `04-settings-chat-row.png` | Settings → `CHAT`: `Clear chat` with its subtitle `Deletes 8 messages on this device` |
| 5 | `05-clear-chat-dialog.png` | `Clear chat?` — *"This deletes 8 messages on this device."* — `Cancel` / `Clear` in red |
| 6 | `06-cleared-snackbar.png` | The moment after `Clear`: `Cleared 8 messages.` over Settings |
| 7 | `07-thread-cleared.png` | Home afterwards: the welcome state and an empty thread |

The count in frame 4 is the count that was on screen: the row is not a fixed
sentence, it is read from the same store the thread is written to, which is what
makes "8 messages" true rather than decorative.

Frame 1 is also the honest part. The colour turn is *in* the history and the
model still answered "your favorite color is not mentioned in this
conversation" — 0.5B parameters do not reliably hold a fact across a turn, and no
amount of plumbing fixes that. The name turn in frame 2 is the same plumbing
working with a fact the model did carry. The difference between the two frames is
the model, not the prompt.

## What changed

| file | what it is now |
| --- | --- |
| `lib/core/chat_log.dart` | the thread on disk: `ChatEntry` (text, mine, failed — a placeholder is never stored), a `ChatLogStore` seam (one JSON string in `shared_preferences` on a phone, memory in a test), a `ChangeNotifier` singleton, and `hasChat`/`clear` so the thread and the Settings row cannot disagree |
| `lib/main_ui.dart` | restores the log before the first frame, writes it on every change, and listens: a `clear` from Settings empties the thread on screen. Settings gains a `CHAT` section whose row is the store's count, behind the same red confirm the model delete already used |
| `lib/core/local_ai_service.dart` | `generateResponseStream(prompt, {history})` — the history is `List<AiTurn>` (who said it, what they said) and `trimAiHistory` caps it at `kAiHistoryLimit = 10`, never starting on the assistant's own words |
| `lib/core/on_device_ai_service.dart` | the turns go to the engine as `ChatTurn`s, which renders them through the model's own chat template — Qwen's is ChatML. Hand-writing `<|im_start|>` around turns the runtime already templates is the one way to get a double-templated prompt, so nothing here does |
| `lib/core/ollama_service.dart` | the PC gets the same history through `/api/chat`, and a caller with no history keeps the exact `/api/generate` request it always sent |

The signature is `(prompt, history:)` rather than one `List<Message>` because the
here-and-now question is not history: it is the prompt, it is answered, and a
caller that has to remember to append it is a caller that will forget once.

## What is covered by tests instead

- `test/chat_log_test.dart` — the store: round trip, an unreadable/half-written
  JSON blob losing nothing else, empty entries refused, clear, listeners firing
  once per real change, and the store read back by a second `ChatLog`.
- `test/main_ui_test.dart` — the screen: a stored thread is on screen at launch,
  a new message is written through, a failure notice is stored as a failure and
  not as an answer, Clear chat's dialog is red and its Cancel keeps the thread,
  and the history handed to the brain stops at the question being asked and at
  ten turns.
- `test/on_device_ai_service_test.dart`, `test/local_ai_service_test.dart` — the
  seam: history reaches the engine as roles, the cap applies, and the fallback
  passes the same history to whichever brain answers.
