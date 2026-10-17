# The Ollama brain — a real model, a real window, and what it said back

Captured 2026-10-17 from the Linux desktop build of the shell
(`build/linux/x64/debug/bundle/nexus`), driven through the real compositor with
`tool/ui_driver.py` — the same machinery `tool/gui_walkthrough.sh` uses (hyprctl
for geometry and focus, `/dev/uinput` for the pointer, `wtype` for the keyboard,
`grim` for the frames). The model is the machine's own **Ollama**, listening on
its default `localhost:11434`, with `llama3.2:latest` installed — which is also
the service's default host and default model, so the app under test needed no
`--dart-define` at all.

Nothing here is mocked: the app opened a socket to Ollama, posted
`{"model":"llama3.2","prompt":…,"stream":false}`, waited, and put what came back
on screen.

| photo | what it shows |
| --- | --- |
| `01-thinking.png` | 0.7s after the send: the user's bubble, and **"Nexus is thinking…"** where the answer will land |
| `02-answered.png` | the same two bubbles once the model replied — the placeholder is gone and **"PONG"** is in its place |
| `03-unreachable.png` | the same app pointed at a dead port: **"Could not reach local AI. Check if Ollama is running on your PC."** |
| `04`–`06` | the same three moments as whole windows (the thread is small; the crops above are the readable version) |
| `07-window-dead-host.png` | the dead-host run, whole window |

The prompt was `Reply with exactly: PONG`, and the answer was `PONG`. That is the
part worth keeping: a canned reply or a broken parse could not have produced it —
the words on screen came from the model, through the service, into the bubble. It
took 13.5 seconds end to end on the first call, which is the model loading into
memory; the request itself is a fraction of that.

`03-unreachable.png` is the *same build* of the app — same code, same widget tree
— with `--dart-define=NEXUS_OLLAMA_HOST=http://127.0.0.1:9`, a port nothing is
listening on. The failure is a sentence in the thread, not a dialog, not a
spinner left running, and not silence. (The desktop binary was rebuilt with the
default host afterwards; nothing in the repository carries that define.)

## What this does not cover

**The live page's thinking state was not driven on hardware**, because the Linux
desktop has no recognizer — the composer says so on screen ("Voice input isn't
set up on this device"), and the live button is inert for the same reason. The
live path is covered by `test/main_ui_test.dart` instead: `the wait for an answer
is a state, not a spinner` holds a stalled request open and checks the blue orb,
the closed microphone, the inert tap, the answer taking the large type, and the
grey "tap to continue" state that follows it — then that a tap clears the page
and listens again. What is *not* proven on hardware is the same path with a real
recognizer feeding it, which is the phone's job.

**The phone has not run this.** The phone reaches the PC over the LAN, which
needs the PC's address in the app (`--dart-define=NEXUS_OLLAMA_HOST=http://<pc-ip>:11434`),
and the failure sentence above is what it will show if it cannot get there — but
that is a claim about the code, checked here against a closed port on loopback,
not a measurement taken across a real Wi-Fi network.

## Where the pieces live

- `lib/core/ollama_service.dart` — the service, its three constants (host, model,
  and the unreachable sentence), and the `OllamaService.override` seam.
- `lib/main_ui.dart` — `_send`/`_answer` for the thread, `_onLiveHeard`/`_liveAnswer`
  for the live page, and `_LivePhase.thinking` for the blue orb.
- `test/ollama_service_test.dart` — the wire: the payload, the four failures, a
  real loopback socket in Ollama's shape, and a refused port.
- `test/main_ui_test.dart` — the screens: the placeholder being replaced, the
  unreachable sentence in a bubble, the blue thinking orb, and the tap that
  follows it.
