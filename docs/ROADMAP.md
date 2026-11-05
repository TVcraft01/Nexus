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
| 3 | Real Linux tools: network status and Wi-Fi settings via `nmcli`, measured, with rollback | todo | — |
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
