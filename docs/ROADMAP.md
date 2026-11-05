# Roadmap

The queue for making Nexus an agent. Read `docs/VISION.md` first; this file is the work order.

Rules for every item: one branch and one PR from fresh `main`, wait for all four CI jobs, merge only by the
gate (`gh pr checks <n> --watch --fail-fast` exits 0 and every job passed), then update this table in that same
PR. Never claim "works" without evidence in the report. Steps that need a human (a phone plugged in, a password
typed) stop and ask; they are never faked.

Freeze until item 2 passes: no UI polish, no fonts, no screenshot work. Bug fixes only.

Status values: `todo` · `in-progress` · `done` · `blocked`.

| # | Item | Status | PR |
|---|------|--------|-----|
| 1 | Agent core contract (`docs/AGENT_CORE.md`) | done | #123 |
| 2 | `lib/core/agent/` — tools, registry, planner, executor + the two scripted conversations | done | #124 |
| 3 | Real Linux tools: network status and Wi-Fi settings via `nmcli`, measured, with rollback | done | #125 |
| 3b | Planner reliability: fast path, registry schema, repair loop, questions over guesses | in-progress | — |
| 4 | Agent definitions as data + background service + local dashboard | todo | — |
| 5 | "Curious" explore tool for an unknown device | todo | — |
| 6 | Earned trust: offer to automate after N approvals of the same action | todo | — |
| 7 | Local user profile with source and a forget button | todo | — |
| 8 | Signals, not audio: notice when the user is stuck | todo | — |
| 9 | Email style learning, explicit opt-in, drafts only | todo | — |
| 10 | Research only: `docs/LISTENING.md` (always-on listening is NOT built) | todo | — |

---

## 1. Agent core contract — `docs/AGENT_CORE.md`

One page, the contract everything else implements: goal → explore → plan → approve → execute → verify → report →
remember.

A plan is a list of steps, each with tool, args, a plain-words description, a risk tier and a rollback.

Risk tiers are enforced in **code**, never by the model:

- `read` — automatic.
- `change` — asks the user.
- `destructive` — asks and the confirmation names the device.

Also required by the contract: auto-rollback when verification fails, an action log, and a kill switch.

**Done when:** the page exists, matches item 2's interfaces, and the three tiers' enforcement point in code is
named.

## 2. `lib/core/agent/` — tool interface, registry, planner, executor

- `Tool` interface: `name`, `description`, `risk`, `dryRun`, `run`, `verify`, `rollback`.
- A registry; the planner goes through `TextGenerationBackend`, returns JSON, and every plan is validated so
  only registered tools can appear.
- An executor that enforces the risk tiers in code.
- Fake tools and a fake device layer — the acceptance tests run offline, with no network and no model.

**Acceptance test A (offline):**

1. "Hi I want to set up my wifi" → Nexus: "Want me to do it?" → "Yes" → progress → "Done, set for best speed and
   guests handled".
2. Assert the plan, the approval, the verification and the report.

**Acceptance test B (offline):**

1. "Can you automatically read my email and answer like me" → asks what it needs (1, 2, 3) → user picks 2 →
   creates an agent and shows where to see it → "will it work all the time?" → offers working hours learned from
   3 weeks of a usage log → user picks 1.
2. The mail tool is **drafts only**; auto-send stays off until the user turns it on.

**Done when:** both conversations pass as scripted tests, the validator rejects an unregistered tool, and a
failing verification triggers rollback in a test.

## 3. Real tools on Linux: network status and Wi-Fi settings

`nmcli` on this PC: band, power save, DNS. Read-only tools first (status, signal, speed); every change arms a
detached confirm-or-revert timer before it writes, never touches an access point's own settings, and refuses to
run while CI is going.

**Rules that ship with the tools:** one change at a time (a lock file, not a promise); a change that could cut the
connection is applied, then has 60 seconds to be confirmed or a process that outlives Nexus puts it back; the
revert is proven by actually rolling a change back, never by reading code. The approval prompt is the session's
plan question in the chat — this build has no terminal UI, and the freeze holds until the core is trusted.

**Measured on this PC (2026-11-04, `Freebox-CA82DC` on `wlp0s20f3`):**

- read-only: 5 GHz (5180 MHz), signal 71–80%, link rate 270 Mbit/s, 2.3–2.7 ms average to the gateway
  (192.168.1.254), 0% loss over 4 packets;
- change path, on a throwaway profile (`nexus-temp-…`, autoconnect off, never activated): band `""` (automatic)
  → `bg`, verified as `802-11-wireless.band=bg`, then rolled back to `""` and the profile deleted; the connection
  in use was untouched (`Freebox-CA82DC, tailscale0, lo` before and after);
- the detached timer: a timer armed by a process that is then SIGKILLed still reverts —
  `test/revert_survival_smoke.dart` proves it, and `tool/arm_timer.dart` reproduces it by hand.

**Real model, five messy asks** (`llama3.2:latest` on this PC, `test/planner_live_smoke.dart`): 4/5 replies were
readable JSON, 1/5 survived the validator. The failures are the planner prompt's, not the validator's: two plans
had steps with no `description`, the DNS ask planned `wifi_band_set`, and the 5 GHz ask left `connection` to a
question. That rate is the first thing to fix next.

**Not tested on this PC:** a real band / DNS / power-save change on the connection in use — only on a throwaway
profile — because this PC's only link is that Wi-Fi, and a self-inflicted drop is not worth the measurement; a
throughput test (the speed tool reports the negotiated link rate and measured gateway latency, not Mbit/s through
the internet); and none of it is wired to the UI yet.

## 3b. Planner reliability

Target: 9 of 10 messy requests give a plan the validator accepts, or one clear question, measured by a test that
runs against a local model.

What was built, in the order it saves a model call:

- **a deterministic fast path** (`lib/core/agent/fast_path.dart`) for known Wi-Fi goals — status, signal, speed,
  band, power save, DNS. With the connection in use injected it plans a change without a model; when a value is
  genuinely missing (which DNS servers, which connection) it asks instead of guessing. Unknown asks go to the model.
- **structured output**: Ollama's `format` field takes a JSON schema as well as the string `"json"`, on
  `/api/generate` and `/api/chat` — structured outputs, documented since 0.5.0 (this PC runs 0.40.6, so it is
  available). `planJsonSchema` builds the schema from the registered tools: one branch per tool, each carrying
  only that tool's arguments. The schema is also put in the prompt, which is what Ollama's own docs recommend.
  `args` deliberately does not mark anything required: a decoder forced to fill a value the user never said would
  invent one, and a question is the rule.
- **a repair loop** (`Planner.maxRepairs = 2`): a plan the validator rejects is sent back with the validator's own
  fault sentences, up to twice, and the model is told a step may only carry its own tool's arguments.
- **one question, not one per argument**: a step missing several required values asks a single plain-words question
  naming them all, and the session offers that instead of running a guessed plan.

**Measured on this PC (2026-11-05, `TVcraft01's Wi-Fi`, 5 GHz, signal 81–88%, `test/planner_live_smoke.dart`, 10
asks: clean, vague, wrong-tool traps, and missing arguments):**

- `llama3.2:latest` (2.0 GB — the only model installed, so it is also the largest installed): **10/10 answerable**,
  10/10 readable JSON, 8/10 planned with no model call, 2 model calls in total. Both model asks (“my wifi is slow
  can you fix it”, “why does my internet keep dropping”) came back as questions rather than plans, which is the
  right answer for a vague ask that names no setting.
- the same 10 asks without the per-tool schema and the repair rule: 8/10. Both failures were the model putting
  `connection`/`value` on `wifi_status`/`wifi_speed` and repeating it through both repairs, because the shared
  `args` object allowed any tool's argument on any step.
- the fast path also fixes the three item-3 failures: the DNS ask is `wifi_dns_set` (never a band change), and the
  5 GHz ask uses the connection in use instead of leaving `connection` to a question.

**Not tested:** a second real model (only `llama3.2` is installed, so “largest installed” is the same model); the
phone's on-device backend, which does not implement structured output and would take the prompt-only path; and no
UI wiring, which the freeze still holds.

## 4. Agent definitions as data

Goal, tools, schedule, approval policy, status — stored as data, run by a background service on the PC with
start / pause / stop and a **local-only** dashboard URL. An opt-in local usage log so Nexus can propose working
hours.

## 5. "Curious" explore tool

Read-only discovery of an unknown device: mDNS, UPnP, HTTP/SSH banners. Builds a device profile, and asks the
user exactly one question if it still needs more.

## 6. Earned trust

After N approvals of the same kind of action, offer to make it automatic. Never for destructive actions,
messaging as the user, money or security settings. Always with undo, a log and a revoke button.

## 7. Local user profile

Routines, preferences, corrections. Every fact shows its source and a "forget" button. Stored on the user's
devices only.

## 8. Signals, not audio

Notice when the user is stuck from cheap local signals — repeated failures, repeated asks, errors from tools
Nexus runs, calendar, time of day — and offer help.

## 9. Email style learning

Explicit opt-in. Replies stay drafts until the user enables auto-send.

## 10. Listening — research only

Write `docs/LISTENING.md`: what Android and iOS actually allow, the privacy and consent law issues (other people
recorded), and a design for short, visible, user-started "listen sessions" on the PC. **Build nothing.** Always-on
listening is not built.
