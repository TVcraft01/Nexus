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

The three levels, spelled plainly:

| Level | Tier | Meaning | Behaviour |
|---|---|---|---|
| low | `read` | Reading status; no state changes. | Runs automatically, unless the policy asks about everything. |
| medium | `change` | Changes a setting; reversible by its rollback. | Runs only if the stored policy allows it; otherwise asks. |
| high | `destructive` | Loses data, or removes access. | Never standing: a yes for that one action in that one run. A scheduled run skips it. |

`Tool.risk` defaults to `destructive`: a tool that declares nothing is high, so forgetting to classify one asks
instead of granting execution. A removal/install/command/credential tool is always high.

The enforcement point is `Executor.run`, through a single choke point — `ApprovalGate.check` — not the planner and
not the prompt:

```dart
// lib/core/agent/executor.dart — every step, before any tool is looked up
final verdict = ApprovalGate().check(
  policy: agent.approval,   // the policy stored on the agent
  step: step,               // risk read off the registered tool
  attended: !unattended,    // a schedule cannot ask anybody
  oneShot: approval,        // a yes for this run; never stored
);
```

`run` executes, `needsApproval` asks (attended) or skips (unattended), `blocked` skips and says why. A run that
cannot ask never waits and never assumes yes, and the step it skipped is named in the run's summary.

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

## Security notes: the gate, the logs, and the halt

**The gate is the only door.** A tool can be reached from exactly one place, `Executor.run`, and every step passes
`ApprovalGate.check` before the tool is even looked up. Consequences, all non-negotiable:

- the risk is the registered tool's, so a prompt injection can propose a plan but cannot lower a tier;
- a `destructive` (high) step is never a standing permission: the yes is per action, per run, and is not written
  to the agent, the store or the export path;
- a scheduled run is unattended by definition, so it can never acquire an approval it did not have — it skips the
  step and the last-run summary names it;
- the stored tool list is enforced as a limit, so a plan naming any other tool is refused whole before anything runs.

**Two local logs, two different promises.**

| | Opt-in usage log (`agents.json`) | Audit run log (`agent-runs.jsonl`) |
|---|---|---|
| Records | when the user did the thing | what an agent did, and why it was allowed |
| Default | **off** until the user says yes; turning it off forgets it | on, because a safety record must not depend on remembering a switch |
| Used for | suggesting working hours | checking a run's claims after the fact |
| Cap | 5 000 timestamps | 2 000 lines, rotated to `.1` |

The session's in-memory action log (`action_log.dart`) is a third thing: the "what has it done just now" view in a
chat, with argument digests rather than values.

**The audit log redacts before it writes** — a key that names a secret, a value that looks like a token, and nested
maps — so an audit line never becomes a copy of a credential. It is append-only; a capping rotation keeps one
previous generation so the current file cannot grow without bound.

**The halt is one flag.** The service and the executor share it, so tripping it stops an in-flight run before its
next step and prevents new ones; the dashboard's *Halt all agents* trips it, *Clear the halt* resets it, and nothing
resumes automatically. It never claims to undo work — that is the rollback path, and the report says which of the two
happened.

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
