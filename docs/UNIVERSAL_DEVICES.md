# Universal devices

One assistant on every device you own. Not a separate app with the same logo —
the same assistant, with the same name, the same memory of what you told it, and
an honest line about what each device can actually do.

This is the durable version of that intent, plus the spec for the local profile
that lets Nexus learn how you ask and offer help before you ask for it.

## What makes an action universal

An action is universal when **some device you paired can run it** — not when
this device can. That is the whole design, and it is deliberately a capability
question rather than a promise:

- `core/capability.dart` is the single owner of one fact per action: its id, its
  label, one verified example, and the **platforms whose executor can run it**.
  Two invariants are enforced by `test/capability_test.dart`: every
  `AgentActions` id has exactly one entry, and every non-null example parses
  back to its own action.
- `ui/device_executor.dart` decides *how* an action runs, per platform. The
  registry's platform list is only believable because that switch backs it.
- A paired device announces what it can run, with provenance (which device,
  which version). A phone can therefore offer a PC action it cannot perform
  itself, and the PC is the one that executes it.

An ask resolves one of three ways, and the assistant must say which:

1. **This device runs it** — local executor, local result.
2. **A paired device offers it** — the request crosses the encrypted local mesh,
   and the receiving device re-gates it against its own per-action approval
   table before running anything.
3. **Nobody can** — the honest refusal, or a teach question. There is no fourth
   path where the assistant pretends.

No cloud, no account, no model in the matching path. Device names, resolved
targets and outcomes are worded per device, so "my pc" and "my laptop" resolve
against what each peer actually reported — see `docs/DEMO.md` for the walked
file-fetch vertical.

## Learning to help

A profile of how *this* user asks, built on this device from two local sources —
the ask log and the dream pass — and used to offer help before it is requested.

**Status, stated plainly, because the rest of this doc describes both:**

| Piece | Today |
|---|---|
| Ask log (`core/query_log.dart`) | **Ships.** JSONL, local, size-capped, buffered. |
| Repeated asks → leading chips (`core/predictions.dart`) | **Ships.** Count ≥ 2, top 3 lead the chips. |
| Corrections → teach funnel (`core/dream.dart`, `learnable`) | **Ships** as a proposal the user confirms one tap at a time. |
| Dream review sheet | **Ships**, behind "What I still misunderstand". |
| Routines by time / device | **Not built.** Specified below as a shape, not a claim. |
| Accept / dismiss feedback, suppression | **Not built.** Specified below. |
| "Why this suggestion?" | **Not built** as a feature; the evidence it would name is already computed. |
| Per-item forget of a profile item | **Not built.** Only `memory.forget` for facts exists. |

Do not read this section as a description of shipped behavior past the rows
marked *Ships*.

### The profile and where it comes from

**The ask log** is the raw material: one JSON line per event, appended by
`QueryLog`, buffered and capped at 512 KiB with exactly one rotated page
(`.1`), so history is a rolling window rather than an unbounded record. Kinds
today: `ask`, `learned`, `sync`, `fact`, `fact-sync`, `call`, `remote`. A torn
or foreign line is skipped, never fatal — a bug log must not break the
assistant it observes.

**Repeated asks.** `Predictions.habits` counts normalized phrases across real
asks only: entries logged while a clarification was open carry the user's typed
*answer* (in the `teach:` / `which:` routes) and are skipped, as are bare
agreement words, so "yes" can never become a suggestion. A phrase counts as a
routine at two occurrences; the view leads with at most three. Their own words
lead the chips, ahead of any registry example.

**Corrections.** A correction is the strongest evidence the system gets, and it
must never be treated as an ask. `DreamPass._teachEntries` keeps that
distinction explicit: the failed phrase lives in the route (`teach:<phrase>`),
while the logged input is whatever the user typed — "no", the correction, the
same typo again. Repetition is counted only when the input normalizes back to
the phrase itself, i.e. a genuinely fresh re-ask. `DreamPass.learnable`
requires that at least twice, drops phrases shorter than six characters as too
ambiguous to guess at, requires similarity ≥ 0.68 to something the user already
taught, and refuses to propose a meaning the interpreter cannot actually
learn — the meaning is always the user's own teaching applied to their own
variant, never an invention.

**Routines by time and device (not built).** The intended shape: key a habit by
`(normalized phrase, day part, device kind)` and admit it only when it repeats
at that time and on that device on **two or more distinct days**, so one long
afternoon cannot manufacture a routine. Evidence must be local: this device's
own log entries, its own clock, and the device kind it knows from pairing —
never another device's log. The point of the device axis is honesty about
capability: "every morning on this phone" and "on the PC" are different offers
because they may be different actions.

### Offering, not acting

Suggestions are offers. They appear as chips under the greeting or above the
composer, and as the dream review's one-tap proposals. Three rules hold them
together:

- **An offer must be actionable.** A chip that does nothing is worse than a
  missing chip, which is why the registry invariant (every example parses to
  its own action) and `learnable`'s "the meaning must parse" check exist.
- **The assistant never guesses a meaning.** It proposes the user's own
  teaching, applied to the user's own variant, and waits.
- **Short or ambiguous phrases are not offered at all.** A wrong guess stays a
  question.

### Accept and dismiss train it

Today the only feedback signal is implicit: tapping a chip submits the phrase,
which writes an `ask` line, so a tap *is* evidence and the next ranking moves.
That is "accept" with no record that the offer was accepted.

The missing half is **dismiss**, and it is the half that matters most: an
assistant that cannot be told "not this" becomes a nag with no memory of being
refused. The spec:

- A dismiss control on each suggestion writes a `suggestion` event carrying the
  phrase, the decision (`dismissed`), and **what produced the offer** (habit,
  dream proposal, routine, registry example). Without that last field a
  dismissal cannot be attributed, and an unattributable dismissal can only be
  applied to everything — which is how a user loses the good suggestions with
  the bad.
- **Dismissals suppress repeats.** A dismissal of `(phrase, source)` suppresses
  that pair. Repeated dismissals of one source suppress the *class* for that
  user, because a person who rejects three "you usually ask this" cards is
  telling you about the class, not the three phrases.
- Suppression is a **filter applied before ranking**, not a deletion. The log
  keeps the evidence, so the decision stays explainable and reversible, and a
  suppression can expire if the user later starts asking the phrase again.
- A dismiss is **not a teach**. It must never write a learned phrase, and it
  must never suppress the phrase from being *answered* — only from being
  *offered*.
- Dismiss and forget are different, and the UI must not blur them: **dismiss is
  about the offer**, **forget is about the record**.

### "Why this suggestion?"

Every suggestion owes the user one line in their own words: "you asked this four
times", "you taught *sam smith* and kept saying *sam*", "you ask this around 7am
on this phone".

The implementation constraint is the part worth writing down: **the reason must
come from the same computation that produced the offer.** The offer should carry
its evidence — phrase, source, count, and the log entry ids it counted — rather
than re-deriving a reason at display time from a fresh scan. Two independent
computations of "why" will eventually disagree with the suggestion they explain,
and a suggestion whose reason is wrong is worse than no reason, because the user
cannot tell which half lied.

Corollary, in the same spirit as the rest of this codebase: if an offer has no
evidence it can name, it must not be shown.

### Per-item forget

Every profile item must be removable on its own: "forget that I always ask
this", scoped to that phrase. The rules:

- Forget removes **that item's contribution** — the counted log entries for that
  phrase, or a tombstone where the raw page is shared or read-only — so the
  habit count drops to zero and any routine or dream proposal built on it
  disappears with it.
- It must not touch other phrases, and it must not rewrite the log page
  wholesale: offering "delete everything" as the only control is not a forget
  feature, it is a reset.
- It must be **real**, not a UI hide. An item that is hidden from the list but
  still counted is precisely the bug this exists to prevent.
- Facts already have `AgentActions.memoryForget`; the profile's own items need
  the same per-item reach, through the same single-funnel discipline the store
  uses elsewhere.

### No data leaves the device

The promise, stated precisely so it can be checked:

- **The ask log is a local file.** It is never uploaded, never sent over the
  mesh, never included in a peer request. `Predictions` and `DreamPass` are
  pure functions over its lines — no model, no network, no telemetry. The
  profile is computed on read, so there is no second copy that could drift or
  be forgotten about.
- **What a suggestion teaches does travel** — but only as ordinary memory. A
  learned phrase, a default, a fact or a reminder enters the normal sync path
  and reaches devices you paired, over the local network. That is not the
  profile leaving the device, and it is not a cloud; it is the thing the user
  chose to remember. The doc says so out loud because the distinction is easy to
  lose in a promise as short as "nothing leaves the device".
- **Escalation sends the question, not the profile.** When a phone escalates to
  a paired PC's brain, the request is the ask — the habit list, the dream
  insights and the log stay where they were computed.
- Nothing in the profile may be attached to a peer request for any other
  reason. If a future feature wants that, it is a change to this promise and
  belongs in this file first.

### Guardrails

- Never invent a meaning; propose only what the user taught.
- Never offer what cannot be acted on.
- Never count a correction as an ask, and never count an answer inside one
  session as persistence.
- Never build a routine from another device's log.
- Never suppress an answer — only an offer.

### Where a change lands

- A new ask-log event kind → `core/query_log.dart` (one method per kind).
- Habit mining and routine keys → `core/predictions.dart` (pure, injectable
  clock when time becomes a key).
- Gap detection and teach proposals → `core/dream.dart` (pure).
- Offers, dismiss controls and the review sheet → `ui/assistant_view.dart`; the
  known debt is that the dream sheet and the chips still live in the view, so
  extract before growing them.
- Suppressions, dismissals and forget tombstones → `NexusStore`, persisted,
  written through the existing single funnel rather than straight from the
  service.
- Tests: `test/dream_test.dart` and `test/skills_test.dart` cover the pure
  mining today; dismissals and per-item forget need their own coverage that
  asserts the *absence* of a repeat as well as the presence of a suppression.
