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
| `NexusSwitchRow` | Settings ×4 | as `NexusRow` | as `NexusRow` | — | the control is now `CupertinoSwitch`, which drives its own thumb; the row's own spring is unchanged. |
| `NexusRow` | Files sheets (destination picker, send-to) | **same frame** | spring | yes | was a Material `ListTile` (~100 ms, ripple); it is the shared row now, so a sheet's list moves like a page's. |

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
| `showCupertinoSheet` (pair sheet, device detail, destination picker, send-to, dream review) | yes — the framework's grabber is wired to the same recogniser that pops the route | enter: fixed 500 ms (`sheet.dart` `transitionDuration`) with `fastEaseInToSlowEaseOut`; **the drag itself is 1:1**, `popDragController.value -= delta` | **yes** — `_CupertinoDragGestureController` drives the route's own animation controller from the live drag, and a released drag continues from wherever it got to | **yes** — release is decided *by* velocity: `_kMinFlingVelocity` = 2.0 screen-heights/s, and the commit/cancel split is `popDragController.value > 0.52` when the finger is slow (`sheet.dart`) |
| `showNexusActions` (`CupertinoActionSheet` via `showCupertinoModalPopup`) | the sheet slides with the barrier; the actions are `CupertinoButton`s | framework popup transition; the sheet is a real vibrancy layer — `BackdropFilter` at `CupertinoPopupSurface.defaultBlurSigma` inside a 12pt `ClipRSuperellipse` (`dialog.dart:1309-1316`) | dismissible: tap the barrier, or Cancel | — |
| Material `showModalBottomSheet` (before) | yes, from the theme's handle | enter 250 ms (`material/bottom_sheet.dart:27`) | yes | yes |
| Pair sheet's own grabber bar | — | — | — | **Deleted** (`3b4274e`): a second, behaviour-less bar 100 px below the framework's. |

Every sheet in the app is Cupertino's now (`71c3044`), so the grabber, the
barrier, the corner radius and the drag are the framework's own. What a
Cupertino route does **not** provide is a background: a Material sheet paints
one for you, so the content paints its own (`NexusSheetSurface`), which is why
the sheet's colour is written down in one place rather than in each caller.
Every converted sheet hands the route's own `ScrollController` to its
scrollable — that controller *is* the mechanism: the route watches it to know
when the content is at its top, which is the moment a downward drag stops
scrolling and starts dismissing. A themed Material handle could only imitate
that. The one deviation left: an untouched sheet still enters on a fixed
500 ms curve, which is a framework constant and not gesture-driven.

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

## 5. Pull to refresh — now the framework's own, and part of the scroll

Before: `RefreshIndicator` (Files) returned the indicator with
`animateTo(…, duration: 150 ms)` then `animateTo(0.0, duration: 200 ms)`
(`material/refresh_indicator.dart:29-33, 544-570`) — a **fixed curve, with no
spring and no velocity handoff** from the release, and no hook to give it one.

Now (`71c3044`): the Files list is a `CustomScrollView` whose first sliver is a
`CupertinoSliverRefreshControl`, so the control is *inside* the scroll rather
than an overlay on it — the pull moves with the finger, because it is the scroll
that is moving. Two things follow from the SDK, not from assumption:

- the callback fires **from the drag state**, the moment the indicator's extent
  passes `refreshTriggerPullDistance` = 100, with the finger still down —
  `refresh.dart:494-505`, plus a `HapticFeedback.mediumImpact()` — where the
  Material indicator waits for the release;
- the retraction is not an animation of its own: `refresh.dart` contains **no**
  `AnimationController` and **no** `Duration(…)` at all. The state machine
  (`inactive → drag → armed → refresh → done`) drives the sliver's box extent,
  and the physics that put the list past the edge bring it back.

Pinned by a test that pulls the real widget (`test/files_view_test.dart`):
the control occupies no space at rest, it is on stage mid-pull, the listing is
re-asked while the finger is still down, and it is back to no space after the
release.

## 6. Continuous loops (are any of them decoration?)

| Loop | Rate | Verdict |
|---|---|---|
| `NexusCore` orb spin | one rotation per 12 s (0.083 Hz), **only while the core is active** (`nexus_core.dart:118-142`) | slower than the skill's ~0.2 Hz warning; means "work in progress" |
| `NexusStatusDot` pulse | 1400 ms repeat, only for `working` | status, not decoration |
| `CircularProgressIndicator` | framework, ~1333 ms | means bytes are moving |
| `CupertinoSliverRefreshControl` | the scroll's own physics; no independent animation exists in the widget (`refresh.dart`, no `AnimationController`) | means data is being re-read |
| Fixed-duration state changes | `NexusMotion.fast/base/slow` = 120/220/320 ms | used for colour, opacity, and one expando |

One fixed-duration **expander** remains: the Devices detail sheet's "Advanced"
row uses `AnimatedCrossFade(duration: NexusMotion.base)` — 220 ms, not
interruptible, not a spring. Open, and cheap if it ever annoys anyone.

## 7. The three rules that are not about interaction

| Rule | State |
|---|---|
| **Materials, not flat bars** (6) — nav bars, sheets and composers should be translucent layers with content scrolling underneath | **now met by the controls that are Cupertino's**: `CupertinoTabBar` and `CupertinoNavigationBar` blur once their fill is not opaque, and `CupertinoActionSheet` is a real vibrancy layer (`dialog.dart:1309-1316`). Nexus itself still paints **no** `BackdropFilter` (the only blur of its own is the core orb's `MaskFilter`), so the composer and an opaque page surface stay flat on purpose: a blur behind the composer is a real per-frame cost on the phones this ships to. The remaining gap is the *page* chrome the app owns rather than borrows. |
| **Typography tracking is size-specific** (7) | **met.** `NexusType` tracks each size on purpose: `display` −0.5, `title` −0.2, `body`/`caption` 0, `overline` +0.8 — negative as text grows, positive for small caps. |
| **Reduced motion** (14) | **met, and extended.** `NexusMotion.scaled()` collapses durations when the OS refuses animation; `NexusStatusDot` and `NexusCore` stop their tickers; `NexusPressable` keeps the instant tint and drops the spring. Tested. |

## 8. Defect count

Of the interactive elements audited:

- **2 controls with no press feedback at all** (rule 1): the assistant's brain
  status line, and the "Or teach me what this means" affordance. Both were bare
  `GestureDetector`s. **Fixed** (`8936cee`): both are `NexusPressable` now, so
  they tint in the frame the finger lands and settle on a spring.
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
- **1 fixed-duration return** (pull to refresh). **Fixed** (`71c3044`): the
  control is a sliver of the scroll, so the pull follows the finger and the
  refresh starts under it. See §5.
- **1 fixed-duration expander** (Devices → Advanced, 220 ms
  `AnimatedCrossFade`). **Open**, and cheap: nothing about it is gesture-driven.
- **1 structural rule partly met** (translucent materials): met by the Cupertino
  chrome the app borrows, open for the surfaces it owns. **Open, by choice.**

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

## 10. The Cupertino pass (later the same day)

What changed since, judged by the same four questions. Every framework claim
below was read in the installed SDK, with the line cited.

| Control | Down? | Motion | Grab? | Velocity | There is no |
|---|---|---|---|---|---|
| `CupertinoTabBar` (phone shell) | the bar is not a control: each item is a `GestureDetector` that calls `onTap` | **none** — selection swaps instantly | — | — | iOS does not animate a tab change; a destination is a place, not a state |
| `NexusSidebar` (desktop shell) | same frame | `NexusPressable` spring | yes | — | — |
| `CupertinoNavigationBar` (pushed pages) | — | the bar's fill **lerps from the page colour to the bar colour** with the scroll-under value (`nav_bar.dart:746-757`), and blurs once it is not opaque (`:253-255`) | — | — | a chrome bar that is opaque at rest: iOS shows the material only once content is under it |
| `CupertinoPageRoute` (About, Scan, Cable) | — | the framework's own transition | yes | yes — `CupertinoRouteTransitionMixin`'s back gesture is a 1:1 drag that decides commit vs cancel from release velocity | — |
| `CupertinoSwitch` | the switch owns its thumb | the framework's | yes | — | — |
| `CupertinoActivityIndicator` | — | loop, but only while work is actually in flight | — | — | — |

Measured on the phone, not inferred: the tab bar is a 50dp bar under the
platform's inset, with a full-width hairline on top, four items centred at
134/404/674/944 px (the eighths of a 1080px screen), the selected glyph in the
accent `#0a84ff` and the rest in `#8a94a6`, and a fill of `#11161f` over a page
of `#0b0f14` — the translucent surface, composited. The About page's bar at
rest measured the page colour `#0b0f14`, which is rule 12's *scroll edge*, not
a missing background: the page is shorter than the screen, so there was no
scroll-under state to photograph.

**Still open** at the time of writing: pull-to-refresh was Material's
`RefreshIndicator`, the sheets were `showModalBottomSheet`, and the two
`GestureDetector`s in `assistant_view.dart` showed nothing on press. All three
were closed later the same day — §11.

## 11. Sheets, the pull, and the last two bare gestures

| What | Was | Is | Rule it now meets |
|---|---|---|---|
| A sheet (pair, device detail, destination picker, send-to, dream review) | `showModalBottomSheet` with a themed grabber | `showCupertinoSheet` with the framework's grabber, its own drag-to-dismiss, and the page behind pushing back (`71c3044`) | 2 (grab), 4 (velocity — the release is decided by the finger's speed) |
| A short list of verbs (file actions, conversation menu) | a page-sized sheet holding two rows | `CupertinoActionSheet` — the iOS share-sheet shape, blurred and tap-outside-dismissible (`71c3044`) | 6 (a real vibrancy material) |
| Pull-to-refresh (Files) | `RefreshIndicator`, fixed 150/200 ms | `CupertinoSliverRefreshControl`, fired from the drag at the trigger distance (`71c3044`) | 1 (it answers the finger that pulled it), 4 (the scroll's own physics bring it back) |
| The assistant's brain strip, and "Or teach me what this means" | bare `GestureDetector`s: nothing on press | `NexusPressable` (`8936cee`) | 1 (feedback in the frame the finger lands), 3 (a spring) |
| Text size | fixed pixels | the platform's scaler, clamped 0.85×–1.5×, with the row height following it (`111944c`) | 7 (Apple's Dynamic Type), and the clamp is the honest part: past 1.5× this layout is not a smaller problem, it is a different one |

Measured, not inferred, where measurement was possible: the pull-to-refresh is
pinned by a widget test that drags the real list (the control occupies no space
at rest, is on stage mid-pull, the listing is re-asked while the finger is still
down, and it is back to no space after the release). The sheets and the Dynamic
Type clamp are pinned by widget tests too. What could **not** be photographed
this pass is the phone: `adb` had no device on the bus, so the sheets' on-device
appearance and the 1.3× font-size rendering are verified by the platform's own
widgets and geometry rather than by a screenshot.
