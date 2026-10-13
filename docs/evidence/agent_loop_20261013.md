# The model can call a tool — 2026-10-13

Until this pass the local model answered and did not act. `local_llm_20261012.md`
says it plainly: *"The model answers; it does not act. It is told to point at
real commands rather than invent actions, and nothing parses its words into
commands."* This is the pass that closes that gap for two read-only verbs: the
model can list one of the user's folders and fetch a file from a paired
device, see what the tool found, and answer from it.

## The shape

A phrase the interpreter does not understand still raises the teach card, and
the card still hands the exchange to the brain. What changed is what the brain
can *do*:

- `lib/core/agent_tools.dart` — the tool vocabulary, the prompt block, the
  parser for the model's `TOOL:` line, the safety gate, and the real runner
  (a folder listing on this device, the existing fetch from a paired one).
- `lib/core/agent_loop.dart` — the loop: ask the model, parse its call, run it
  (at most two per exchange), hand the result back as an observation, and let
  the model answer from it.
- `ConversationEngine.converse` runs the loop and swaps one card through
  Thinking → "Looking in Downloads…" → the answer, so the tool call is visible
  while it runs and the result replaces it. No new screen.
- `CommandService.toolFileFetch` gives the model's `get_file` the *same*
  resolution a typed "get report.pdf" uses (named device, only reachable peer,
  or the last one a fetch ran against), and the view runs it through the same
  executor — so a tool-initiated fetch lands, is remembered in Files → Recent,
  and reports exactly like a typed one.

## The protocol: template, not native

The runtime package can do native tool calling — `llamadart` 0.11.1 exposes
`LlamaEngine.complete(..., tools: [...])`, grammar-constrained by the model's
own chat template, with `LlamaCompletion.toolCalls` on the way back. The
product does not use it: `Llm`'s runtime seam is one text request and one text
answer (`LlmRuntime.generate`), and the same seam is what the phone's
tiny-brain channel and the desktop's Ollama fallback share. A text protocol
works on every brain behind that seam; a native call only on one. So the
system prompt carries the tool block, and the loop parses the model's words:

```
You can also run two read-only tools on this device when the user asks:
- list_local_files {"dir": "Downloads"} — lists what is in one of the user's folders. "dir" is exactly one of: Downloads, Documents, Pictures.
- get_file {"name": "report.pdf", "from": "My PC"} — fetches a file the user named from one of their paired devices. "from" may be left out.

To run one, reply with exactly one line and nothing else:
TOOL:<name> {"arg": "value"}

For example, the user asks "what's in my Downloads?" — reply exactly:
TOOL:list_local_files {"dir": "Downloads"}
```

Native tool calling is a real follow-up (see Limits): it would need the runtime
seam widened to carry tools, and a model on this machine to prove it against.

## Safety, as three walls

1. **The tool set.** Two verbs, both read-only. There is no delete, no move, no
   write, and no way for a model to invent one — an unknown name is refused by
   the parser before anything else runs.
2. **The gate.** `toolRefusal` runs the *user's* words against the tool the
   model asked for: a listing needs a mention of files or folders, a fetch
   needs a fetch-ish verb or a file name. "Delete everything" cannot run a
   tool no matter what the model writes.
3. **The fallback.** A refused or fumbled call is dropped from the answer —
   protocol syntax never reaches the user — and when that leaves nothing to
   say, the model gets one more ask *without* the tool block: it is not
   choosing now, only answering.

## Live probe (this PC, headless, no GUI)

`flutter test test/llm_tool_probe.dart` — the product's own `Llm` fetching and
verifying the pinned models, the real loop, the real `LocalToolRunner`, and a
real Downloads folder holding `report.pdf`, `holiday.jpg` and `invoices/`:

```
DESKTOP-1.5B READY status=LlmStatus.ready in 4s
DESKTOP-1.5B ASK "what is in my downloads?"
DESKTOP-1.5B   RAW "TOOL:list_local_files {"dir": "Downloads"}"
DESKTOP-1.5B   PARSED list_local_files {dir: Downloads}
DESKTOP-1.5B   GATE allowed
DESKTOP-1.5B   LOOP ran=[list_local_files] reachable=true answer="In your Downloads folder, there are three files: holiday.jpg, invoices/ and report.pdf."
DESKTOP-1.5B ASK "hello"
DESKTOP-1.5B   RAW "Hello! How can I assist you today?"
DESKTOP-1.5B   LOOP ran=[] reachable=true answer="Hello! How can I assist you today?"
PHONE-0.5B READY status=LlmStatus.ready in 0s
PHONE-0.5B ASK "what is in my downloads?"
PHONE-0.5B   RAW "TOOL:list_local_files {"dir": "Downloads"}"
PHONE-0.5B   PARSED list_local_files {dir: Downloads}
PHONE-0.5B   GATE allowed
PHONE-0.5B   LOOP ran=[list_local_files] reachable=true answer="There are 3 items in your downloads folder: holiday.jpg, invoices and report.pdf."
PHONE-0.5B ASK "hello"
PHONE-0.5B   RAW "TOOL:list_local_files {"dir": "Downloads"}"
PHONE-0.5B   PARSED list_local_files {dir: Downloads}
PHONE-0.5B   GATE the ask does not mention files or folders
PHONE-0.5B   LOOP ran=[] reachable=true answer="Hello! How can I help you today? ..."
```

Both sizes really do it: a real TOOL line, a real folder, the real names in the
answer. The 0.5B's file answer names the folder contents; its greeting shows
the second wall doing its job — the example in the prompt is catchy enough that
the 0.5B copies it for "hello", the gate refuses, and the plain retry answers
the greeting properly instead of asking the user what "hello" means.

Three runs to get there, and the failures are the interesting part:

1. **Without the example**, the 0.5B wrote `TOOL:dir {"arg": "Downloads"}` —
   the right shape with an invented name and key. The parser refused (unknown
   tool), nothing ran, and the user got nothing. The 1.5B wrote the exact call.
2. **With one worked example**, the 0.5B copied it correctly for the file ask
   and copied it wrongly for the greeting (see above) — the gate caught it, and
   the retry answered.
3. The retry needed a plain re-ask rather than a null: refusing a call must not
   turn a greeting into a teach card.

## Checks

- `flutter test` — **1003 passed, 2 skipped, 0 failed**. Nine of them are the
  loop's own (`test/agent_loop_test.dart`): the real listing and the names
  reaching the answer, a plain hello with no tool and one ask, a call the ask
  did not imply never running, a fumbled line falling back, a refused call
  still getting a plain answer, the in-flight card, and the listing's wording.
  Two more drive the view: the parser owning a typed fetch (the model is never
  asked), and a model-asked fetch running through the real executor.
- `flutter analyze` — **60 issues, all pre-existing infos, 0 errors, 0
  warnings** (this pass adds none).
- `git status` — note for whoever reads the tree: another thread's uncommitted
  work was present while this pass ran (`knownOpenTargets` in
  `agent_contract.dart`, the empty-reply wording and throw handling in
  `conversation_engine.dart`). It is *not* in this pass's commit; the commit
  contains this pass's hunks only, verified green in a throwaway worktree.

## Honest limits

- **The parse is a protocol, not a grammar.** A fumbled line is dropped, never
  repaired; a model that names `dir` instead of `list_local_files` gets no tool
  until the prompt teaches it otherwise.
- **The 0.5B needs the example, and over-triggers with it.** On a greeting it
  spends one generation on a call it may not make; the gate and the retry make
  the outcome right, the latency is real.
- **Only two verbs, only reads.** Listing, and a fetch that already existed.
  No move, no write, no delete — deliberately.
- **The listing is one level deep**, capped at 25 names.
- **A tool fetch does not show the fetched-file card.** The file lands, is
  remembered in Files → Recent, and the model reports where it went; the
  tap-to-open object card is what a *typed* fetch still gets.
- **Native function calling is unused**, though the runtime supports it. That
  path would make a weak model's call grammar-correct instead of
  prompt-correct; it needs the runtime seam to carry tools and a model to
  prove it against.
