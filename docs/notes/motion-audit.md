# Nexus — motion audit

Read-only pass over `lib/ui/`, 2026-10-09. The standard is
[Apple's motion rules as distilled by Emil Kowalski][skill] — an interaction
guide, not a visual one: this app's colours, spacing and type are already
written down in `docs/notes/design-system.md`. What is measured here is what
happens between the finger and the pixel.

[skill]: https://github.com/emilkowalski/skills/blob/main/skills/apple-design/SKILL.md

Method: every interactive widget in `lib/ui/` was read, and the claims about
framework behaviour were checked **in the installed Flutter SDK** rather than
recalled — `packages/flutter/lib/src/{widgets,material}/…`, paths cited below.
Column meanings:

- **Down?** — does the control show feedback in the frame the finger lands
  (rule 1, *response*), or only when it lifts?
- **Motion** — what moves it: a fixed duration/curve, or a spring
  (rule 3, *behavior over animation*)?
- **Grab?** — can the animation be caught and reversed mid-flight
  (rule 2, *interruptibility*)?
- **Velocity** — on release of a drag, does the motion continue at the
  finger's speed (rule 4, *velocity handoff*)?

## 1. Rows and list rows — the app's whole grammar

| Control | Where | Down? | Motion | Grab? | Notes |
|---|---|---|---|---|---|
| `NexusRow` (before) | Settings ×10, Devices ×2, pair sheet ×4, destination picker, conversation menu, About | **~100 ms late** | `InkWell` splash: fixed, growing | yes (ink cancels) | `InkWell` does start on down (`ink_well.dart:1171` `_startNewSplash` → `1176` `onTapDown`), but inside a scrollable the tap recogniser holds `onTapDown` until the gesture arena resolves, i.e. up to `kPressTimeout` = 100 ms. A ripple *grows* from the touch point: the surface reads as catching up. |
| `NexusRow` (**now**) | all of the above | **same frame** | accent tint, instant on; **spring** scale 1 → 0.98 | yes | `NexusPressable` reads raw pointer events, so the arena cannot delay the highlight, and a press cancelled by a scroll (past `kTouchSlop`) or by a long press steps back out. |
| `NexusSwitchRow` | Settings ×4 | as `NexusRow` | as `NexusRow` | — | the switch itself is the framework's, unchanged. |
| `ListTile` | Files destination picker | ~100 ms | Material | yes | left as the framework draws it. |

## 2. Buttons, chips, icons

| Control | Down? | Motion | Grab? | Notes |
|---|---|---|---|---|
| `FilledButton` / `OutlinedButton` / `TextButton` / `IconButton` | yes | framework overlay fade, fixed ~200 ms | n/a | Already correct: the pressed overlay is driven by the ink's tap-down, and an opacity-only fade is the one place a duration is allowed. |
| `ActionChip` (suggestion chips, mic) | yes | framework | yes | — |
| `ChoiceChip` (Files, destination picker) | yes | framework | yes | — |
| `PopupMenuButton` (Files overflow) | yes | framework menu fade, no bounce | n/a | A menu that fades in must never bounce — it doesn't. |
| `GestureDetector` — `_brainStatusLine` (assistant, tap to retry the brain) | **no** | none | n/a | **Defect**: a bare `GestureDetector` paints nothing on press. Open. |
| `GestureDetector` — `_teachAffordance` ("Or teach me what this means") | **no** | none | n/a | **Defect**: same, and it opens a dialog — the one control that most needs a hint that it is a control. Open. |
| `InkWell` — assistant header (long press → conversation menu) | ~100 ms, and only if the recogniser exists | ink | yes | A long-press-only surface; the menu itself is the feedback. Open. |
| `InkWell` — "More ways to connect" (pair sheet) | ~100 ms | ink | yes | — |

## 3. Drag surfaces — sheets

| Control | Down? | Motion | Grab? | Velocity |
|---|---|---|---|---|
| Every `showModalBottomSheet` (pair sheet, device detail, conversation menu, dream review, file actions, destination picker) | yes (framework drag handle) | enter: fixed `_kBottomSheetEnterDuration` = 250 ms (`material/bottom_sheet.dart:27`) | **yes** — a dragged sheet follows the finger | **yes** — on drag end the framework flings the controller at the finger's speed (`bottom_sheet.dart:301-311`: `velocity / _childHeight`) |
| Pair sheet's own grabber bar | — | — | — | **Deleted** (`3b4274e`): a second, behaviour-less bar 100 px below the framework's. |

So the sheets already satisfy rules 2 and 4. The only deviation is that an
*untouched* sheet enters on a fixed curve — acceptable, since nothing about
that entry is gesture-driven, and the skill's own table gives a drawer the same
treatment.

## 4. Scroll surfaces

| Surface | Physics | Momentum projection | Carried momentum | Edge |
|---|---|---|---|---|
| Files list (**now**) | `BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics())` | **Apple's** — a `FrictionSimulation` at `kDefaultScrollDecelerationRate` = 0.998, the SDK's own comment naming it *"UIScrollView.decelerationRate (.normal = 0.998)"* (`scroll_simulation.dart:50-51`). At 2000 px/s that throws the list ≈ 998 px | **yes** | rubber band: a `ScrollSpringSimulation` past the edge (`scroll_simulation.dart:100`), with `frictionFactor` falling quadratically from 0.52 |
| Files list (before), every other list in the app | `ClampingScrollPhysics` (Android default) | Android's own curve — `ClampingScrollSimulation` is a port of `OverScroller` (`scroll_simulation.dart:155`) | **no** — the framework's own documentation, `scroll_physics.dart:479`: *"By default, physics for platforms other than iOS doesn't carry momentum"* | hard stop plus the overscroll glow |

Verified in the SDK, not assumed: `BouncingScrollPhysics` overrides
`carriedMomentum` (n² growth, capped at 40 000, `scroll_physics.dart:~795`),
adds `dragStartDistanceMotionThreshold` = 3.5 and doubles `minFlingVelocity`,
and returns a spring rather than a clamp at the boundary. That is Apple's
rules 5 and 9 already implemented in the framework — reachable by asking for
it, but not the default on Android.

## 5. Pull to refresh — the one rule the app still does not meet

`RefreshIndicator` (Files) returns the indicator with
`animateTo(…, duration: 150 ms)` then `animateTo(0.0, duration: 200 ms)`
(`material/refresh_indicator.dart:29-33, 544-570`): a **fixed curve with no
spring and no velocity handoff** from the release. The framework exposes no
hook for either, so honouring this rule means re-implementing the whole
gesture — overscroll detection, threshold, indicator drawing — which is a
project of its own and not a motion tweak. **Documented, not fixed.**

## 6. Continuous loops (are any of them decoration?)

| Loop | Rate | Verdict |
|---|---|---|
| `NexusCore` orb spin | one rotation per 12 s (0.083 Hz), **only while the core is active** (`nexus_core.dart:118-142`) | slower than the skill's ~0.2 Hz warning; means "work in progress" |
| `NexusStatusDot` pulse | 1400 ms repeat, only for `working` | status, not decoration |
| `CircularProgressIndicator` | framework, ~1333 ms | means bytes are moving |
| `RefreshIndicator` spinner | framework | — |
| Fixed-duration state changes | `NexusMotion.fast/base/slow` = 120/220/320 ms | used for colour, opacity, and one expando |

One fixed-duration **expander** remains: the Devices detail sheet's "Advanced"
row uses `AnimatedCrossFade(duration: NexusMotion.base)` — 220 ms, not
interruptible, not a spring. Open, and cheap if it ever annoys anyone.

## 7. The three rules that are not about interaction

| Rule | State |
|---|---|
| **Materials, not flat bars** (6) — nav bars, sheets and composers should be translucent layers with content scrolling underneath | **not met anywhere.** No `BackdropFilter` exists in `lib/ui/` (the only blur is the core orb's own `MaskFilter`). The navigation bar, the sheets and the composer are opaque `surface`. This is a deliberate gap: the design system carries depth with hairlines, and a blur behind the composer is a real per-frame cost on the phones this ships to. It is the largest remaining "not Apple" item. |
| **Typography tracking is size-specific** (7) | **met.** `NexusType` tracks each size on purpose: `display` −0.5, `title` −0.2, `body`/`caption` 0, `overline` +0.8 — negative as text grows, positive for small caps. |
| **Reduced motion** (14) | **met, and extended.** `NexusMotion.scaled()` collapses durations when the OS refuses animation; `NexusStatusDot` and `NexusCore` stop their tickers; `NexusPressable` keeps the instant tint and drops the spring. Tested. |

## 8. Defect count

Of the interactive elements audited:

- **2 controls with no press feedback at all** (rule 1): the assistant's brain
  status line, and the "Or teach me what this means" affordance. Both are
  `GestureDetector`s. **Open.**
- **All 20+ rows and tiles responded on touch-up-ish timing** — on down, but up
  to 100 ms late, and with a growing Android ripple rather than an immediate
  surface response. **Fixed** for every `NexusRow` (one component, all call
  sites) and for the Files rows.
- **1 control with no behaviour at all** — the pair sheet's second grabber bar.
  **Fixed** (`3b4274e`).
- **2 of Apple's scroll rules unmet by the platform default** (no carried
  momentum, hard edges) plus the missing momentum projection on Android.
  **Fixed** for the Files list; the other lists are still clamping, on purpose
  (a settings list is short, and the change is a feel change nobody asked for
  outside the screen being rebuilt).
- **2 visible per-row buttons on every file row** — not a motion defect, but
  the same "the row is the target" principle. **Fixed.**
- **1 fixed-duration return** (pull to refresh) and **1 fixed-duration
  expander** (Devices → Advanced). **Open, documented above.**
- **1 structural rule unmet app-wide** (translucent materials). **Open.**

## 9. What this pass changed, in one line each

1. `NexusPressable` — a shared surface that answers on raw pointer-down, tints
   instantly, moves on a critically-damped spring, and is re-targeted from its
   live value and velocity.
2. `NexusRow` — every row in the app now uses it, and rows can carry a long
   press plus matching accessibility actions.
3. `fileTypeIcon` — one glyph per file kind, one muted colour.
4. Files — drive-app rows (icon, name, size/date, one chevron for folders, no
   per-row buttons), long-press actions sheet, rubber-band list with carried
   momentum, and a row that keeps its shape while it works.
5. `NexusSpring` — Apple's two parameters (damping, response) as a token, so
   the numbers live in one place instead of at each call site.
