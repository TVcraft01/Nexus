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

`nmcli` on this PC: band, power save, DNS. Each tool ships with a measured before/after — `ping` and throughput —
and a real rollback. Run on the actual PC with the approval prompt visible.

**Report:** the numbers, before and after. Not tested on this PC = say so.

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
