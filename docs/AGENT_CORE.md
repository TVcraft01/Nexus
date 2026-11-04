# Agent core — the contract

Read `docs/VISION.md` first. This page is the contract that item 2 implements in `lib/core/agent/`. If the code
and this page disagree, one of them is a bug.

## The loop

goal → explore → plan → approve → execute → verify → report → remember

| Stage | Does | Must not |
|---|---|---|
| **goal** | Restates what the user wants in one sentence, in their words. | Invent a goal the user did not ask for. |
| **explore** | Reads current state with `read`-tier tools (network status, installed tools, device profile). | Change anything to find out. |
| **plan** | Produces a list of steps as JSON through `TextGenerationBackend`. | Name a tool that is not registered. |
| **approve** | Asks once, in plain words, with the risk tier of every step visible. | Ask after the first step already ran. |
| **execute** | Runs the steps in order through the executor. | Run a step whose tier was not approved. |
| **verify** | Calls each tool's `verify()` and reads back the outcome from the device. | Trust "the command exited 0". |
| **report** | One sentence: what changed, what was measured, what it could not do. | Claim success from intent alone. |
| **remember** | Writes what was learned (this device, this user's choice) to local memory with its source. | Store anything on a server. |

## A plan is data

```dart
class PlanStep {
  final String tool;                    // registered name only
  final Map<String, Object?> args;
  final String description;             // plain words, shown to the user
  final RiskTier risk;                  // read off the Tool, never from the model
  final Future<RollbackResult> Function()? rollback;
}

class Plan {
  final String goal;
  final List<PlanStep> steps;
  final List<String> questions;         // asked before approval, not during
}
```

Validation, in `PlanValidator`, before anything is shown or run:

1. Every `tool` is in the registry — an unknown name fails the whole plan, it is not skipped.
2. Every `args` value matches the tool's declared argument types; a missing required argument becomes a question,
   not a guessed default.
3. `steps.length <= kMaxPlanSteps` (8) — a longer plan is a sign the model is looping.
4. `risk` is taken from the registered `Tool`. A risk value in the model's JSON is ignored, and a model that tries
   to supply one is logged as a planner fault.

## Risk tiers, enforced in code

| Tier | Meaning | Behaviour |
|---|---|---|
| `read` | Reading status; no state changes. | Runs automatically. |
| `change` | Changes a setting; reversible by its rollback. | Asks the user first. |
| `destructive` | Loses data, or removes access. | Asks, and the question names the device ("Turn off Wi-Fi on **this PC**?"). |

The enforcement point is `Executor.run`, not the planner and not the prompt:

```dart
// lib/core/agent/executor.dart
if (step.risk != RiskTier.read && !approval.covers(step)) {
  throw TierNotApproved(step);          // nothing runs, plan reported as blocked
}
```

Consequences that follow from this rule and are therefore non-negotiable:

- A prompt injection or a bad model can at most propose a plan; it cannot approve one.
- The approval object names the exact steps it covers, so "yes" to step 1 is not "yes" to step 3.
- A `destructive` step without a device name in its description fails validation.

## Approval

`Approval` records: which steps were shown, which were granted, the user's words, and when. A denial ends the plan
with `denied` and nothing executed. A plan whose steps span tiers is approved tier by tier — the `read` steps already
ran during explore, so the user is never asked about reading.

## Verification and auto-rollback

Every `Tool.verify()` returns `VerificationResult.ok(measured)` or `VerificationResult.failed(reason)`. A step is
done only when verification passes — an exit code is evidence that a command ran, not that the world changed.

On a failed verify (or a thrown `run`), the executor unwinds the completed steps newest-first through their
`rollback` closures and then reports: what was undone, what could not be undone, and the failing reason. Rollback is
best-effort and its own failures are reported loudly; nothing is silently left half-applied, and a tool whose
rollback is not implemented may not be registered at a tier above `read`.

## Action log and kill switch

- **Action log:** one line per executed step — time, tool, argument digest, tier, approval, outcome, verification.
  In memory for the session, like `lib/core/action_audit.dart`; a durable log needs the user's opt-in (item 4).
- **Kill switch:** checked by the executor before *every* step, not only at plan start. Tripped means: stop before
  the next step, report where it stopped, refuse new plans until the user resets it. It never claims to undo work
  by itself — that is the rollback path, and the user is told which of the two happened.

## What the model may decide

May: restate the goal, propose steps, ask a question, choose which registered tool fits.
May not: invent a tool, set a risk tier, mark its own work verified, approve itself, or write to memory as a fact
without a source.

## What item 2 must prove (offline, no network, no model)

1. Conversation A: "Hi I want to set up my wifi" → "Want me to do it?" → "Yes" → progress → "Done, set for best
   speed and guests handled", with assertions on the plan, the approval, the verification and the report.
2. Conversation B: "Can you automatically read my email and answer like me" → asks what it needs (1, 2, 3) → user
   picks 2 → creates an agent and shows where to see it → "will it work all the time?" → offers working hours
   learned from 3 weeks of a usage log → user picks 1. The mail tool is **drafts only**; auto-send stays off.
3. A plan naming an unregistered tool is rejected and runs nothing.
4. A step whose verification fails triggers rollback of the steps before it.
