# Nexus — design system

The one place a visual value is written down. Implemented in
`lib/ui/design/tokens.dart`; `lib/ui/theme.dart` builds `ThemeData` from it.
Under two pages, tables over prose. Apple HIG: **clarity, deference, depth,
consistency**.

## 1. Colour

One accent. No gradient, no glow-wash, no second brand hue.

| Token | Dark (ships) | Light | Role |
|---|---|---|---|
| `accent` | `#0A84FF` | `#007AFF` | Nexus itself — the one interactive colour |
| `accentStrong` | `#409CFF` | `#0062CC` | pressed / lit variant |
| `onAccent` | `#FFFFFF` | `#FFFFFF` | ink on `accent` |
| `bg` | `#0B0F14` | `#F6F7F9` | page behind everything |
| `surface` | `#121821` | `#FFFFFF` | rows, sheets, bars |
| `surfaceElevated` | `#1A2230` | `#FFFFFF` | menus, selected states |
| `surfaceSecondary` | `#161E29` | `#EFF2F6` | chips, avatar fills |
| `separator` | `#232D3D` | `#DCE1E8` | hairline; 1px, never a decorative border |
| `textPrimary` | `#E8ECF2` | `#111820` | body and titles |
| `textSecondary` | `#8A94A6` | `#5A6474` | subtitles |
| `textTertiary` | `#6B7686` | `#6E7887` | dimmest small print |
| `success` | `#34D399` | `#0F7A4A` | online / done |
| `warning` | `#FBBF24` | `#8A5300` | nearby / attention |
| `danger` | `#F87171` | `#B3261E` | failure, destructive |
| `scrim` | `#05080C` @ 80% | `#05080C` @ 40% | behind a modal |

**Rules.** Semantic names only — a widget never spells a hex. Colour is never
the sole carrier of meaning (every status pairs a colour with words). The
accent is used for *state and action*, never as a background wash; a tint is
`accentTint(0.12)` at most, and only behind a chip or a selected row.
The previous mint-teal (`#5EEAD4`) is retired: mint-on-slate at low alpha is
the "AI product" look, and the brief is a shipped Apple app.

## 2. Spacing

Grid: **8pt rhythm**, with a 4pt sub-step for icon/label micro-gaps. Page
margin is **16pt**.

| Token | Value | Use |
|---|---|---|
| `xxs` | 2 | sub-step: label→caption |
| `xs` | 4 | sub-step: icon→label |
| `sm` | 8 | inside a row, chip gaps |
| `md` | 12 | row vertical padding |
| `lg` | 16 | **page gutter** (`page`), group gaps |
| `xl` | 20 | section top padding |
| `xxl` | 24 | section gap (`section`), sheet padding |
| `xxxl` | 32 | empty-state padding |
| `huge` | 40 | rare, hero blocks |
| `page` | 16 | horizontal gutter for phone pages |
| `section` | 16 | vertical gap between two page sections (Apple's 16 between groups) |

## 3. Type

System font. The scale is Apple's text styles, with the tracking each size
needs — tracking is *not* one value for every size. Large display text wants
negative tracking because letters read too far apart as they grow, body copy
sits near zero, and small text wants slightly positive tracking to stay
legible. The numbers follow the SF Pro tracking curve: about -0.086 px per
point in the text range (17pt ≈ -0.43, 16pt ≈ -0.31, 15pt ≈ -0.23,
13pt ≈ -0.08, 12pt = 0, 11pt ≈ +0.06), flattening to about -0.02em once the
face switches to Display at 20pt and up. Leading moves the other way: tight
on large text, looser on the small copy read in sentences.

| Token | Size | Weight | Tracking | Leading | Apple style / use |
|---|---|---|---|---|---|
| `display` | 34 | 700 | -0.68 | 1.2 | Large Title — page title |
| `title` | 20 | 600 | -0.40 | 1.25 | Title 3 — sheet title, "Nexus" |
| `rowTitle` | 17 | 500 | -0.43 | 1.29 | Body 17 — list row title |
| `body` | 15 | 400 | -0.23 | 1.33 | Subheadline — body copy |
| `caption` | 13 | 400 | -0.08 | 1.38 | Footnote — row subtitle, value |
| `overline` | 12.5 | 600 | +0.62 | 1.3 | uppercase group label |
| `button` | 17 | 600 | -0.43 | 1.2 | Headline — button label |
| `callout` | 16 | 400 | -0.31 | 1.31 | Callout — a card's own heading |
| `caption1` | 12 | 400 | 0 | 1.33 | Caption 1 — the smallest size still read as a sentence |
| `caption2` | 11 | 400 | +0.06 | 1.27 | Caption 2 — a device id, a live status line |
| `micro` | 10 | 400 | 0 | 1.0 | the one size below the scale: a number inside a 26pt ring |

Weights are chosen for the face that renders them: Roboto, which Android
actually has, is lighter than SF at the same weight, so a row title takes
`w500` where iOS would say "regular" — it lands at the same optical weight on
the device.

A token owns three things: a size, its tracking and its leading. Emphasis is
not a fourth size — a heading that is heavier says so with
`copyWith(fontWeight: …)` at the call site. That rule is why `callout` exists at
all: the assistant's cards were written as 14pt semibold and 16pt bold for the
same role, and they are one style now (`8936cee`).

### Dynamic Type

Text follows the phone's text-size setting, the way Android's font size and
iOS's Dynamic Type both ask it to. Flutter paints every `Text` at the platform
scaler already, so what the tokens add is the **range**:

| Token | Value | Why |
|---|---|---|
| `NexusType.minScale` | 0.85 | below this, 11pt print stops being legible at arm's length |
| `NexusType.maxScale` | 1.5 | past this, a fixed 64pt row, a 52pt tab bar and a 16pt gutter stop being a smaller problem and become a different layout |
| `NexusType.scalerOf(context)` | the platform scaler, clamped to the two above | for anything that needs to *know* the factor |
| `NexusType.scaled(context, v)` | `v` at that factor | for the things that hold text — a row's minimum height is the first user |

`NexusTextScaling` applies the clamp once, in `MaterialApp`'s builder beside
`NexusCupertinoTheme`, above the navigator, so every route inherits it — pushed
pages, dialogs and the Cupertino sheets alike. Apple's own scale reaches 3×; the
clamp is deliberate, and pinning it (plus the row that grows) is what the
Dynamic Type tests in `test/ui_layout_test.dart` measure.

## 4. Radius, size, motion, shadow

| Radius | Value | | Size | Value | | Motion | Value |
|---|---|---|---|---|---|---|---|
| `xs` | 6 | | `minTouch` | 48 | | `fast` | 120 ms |
| `md`/`row` | 12 | | `row` | 64 | | `base` | 220 ms |
| `lg`/`card` | 16 | | `rowCompact` | 52 | | `slow` | 320 ms |
| `xl` | 24 | | `button` | 48 | | `standard` | easeOutCubic |
|  |  | | `field` | 52 | | `emphasized` | easeOutQuart |
| `pill` | 999 | | `readable` | 640 | | `settle` | easeInOut |

There is no `sheet` radius any more: a sheet is Cupertino's, and its top
corners are the framework's 12pt superellipse (`71c3044`). A radius token the
app no longer paints is a second place to look when a sheet looks wrong.

**Shadow** (new): elevation is carried by hairlines, not drop shadows, except
for two things that genuinely float.

| Token | Value | Use |
|---|---|---|
| `NexusShadow.raised` | `0 8 24 rgba(0,0,0,.28)` | seated composer, floating banner |
| `NexusShadow.sheet` | `0 -8 32 rgba(0,0,0,.32)` | modal sheets |

**Motion means something is happening** — never decoration. All durations go
through `NexusMotion.scaled(context, …)`, which collapses to zero when the OS
asks for reduced motion.

## 5. Components

**Card / `NexusGroup`** — a surface to group rows, not a decorated box:
`surface` fill, `radius 16`, 1px `separator` border, rows divided by a
hairline inset 16pt from the left.

**List row / `NexusRow`** — min height 64 (52 compact); 16pt horizontal
padding; optional leading icon 20pt at `textSecondary`; title `rowTitle` at
`textPrimary`; subtitle `body` at `textSecondary`; trailing value
right-aligned, `body`, `textTertiary`; chevron 20pt `textTertiary` when the
row navigates. The whole row is the target (≥48pt).

**Settings row** — a `NexusRow` inside a `NexusGroup` under a
`NexusSectionHeader`. Label left, value or control right, chevron on
navigation, switches on toggles with the **whole row** as the target.

**Header** — title (`display`/24) + one line of `body` context. **No trailing
icon buttons by default**: secondary actions live in a long-press menu or a
section of Settings; a header holds at most one primary action, and only when
the screen has no better home for it.

**Primary button** — exactly one per view, `FilledButton`, accent fill,
white label, radius 12, 48pt tall. Secondary = `OutlinedButton`;
tertiary = `TextButton`. **Style, not size, carries the hierarchy.**

## 6. Cupertino — which widget is iOS, and where

The app is Material-hosted (`MaterialApp`, because the theme, the tokens and
most of the surfaces are Material) with **Cupertino where the platform's own
idiom is the product**:

| Thing | Widget | Note |
|---|---|---|
| Phone navigation | `CupertinoTabBar` | translucent; the framework blurs what is behind it |
| Desktop navigation | `NexusSidebar` | iOS puts a sidebar under a pointer, not a tab bar |
| A pushed page | `CupertinoPageScaffold` + `CupertinoNavigationBar` | translucent bar; the page scrolls under it |
| A push | `CupertinoPageRoute` | horizontal slide, edge-swipe back |
| Toggles | `CupertinoSwitch` | in the app's accent, not the system green |
| Yes/no dialogs | `CupertinoAlertDialog` | destructive action red, no filled button |
| Indeterminate progress | `CupertinoActivityIndicator` | determinate progress stays `CircularProgressIndicator` — Cupertino has no ring that shows a value |
| A sheet | `CupertinoSheetRoute` (`showNexusSheet`) | framed by the sheet's own `NexusSheetSurface`; the grabber, the corners, the page-behind push and the drag-to-dismiss are the framework's. **Not** `showCupertinoSheet`: that wrapper drops `showDragHandle`, so the handle it is asked for never appears (`cupertino/sheet.dart:199-206`) |
| A short list of verbs | `CupertinoActionSheet` (`showNexusActions`) | blurred vibrancy, separated Cancel, tap-outside dismisses |
| Pull to refresh | `CupertinoSliverRefreshControl` | a sliver of the scroll, so the pull follows the finger; needs a `CustomScrollView` |
| Text size | `NexusTextScaling` | the platform's scaler clamped to 0.85×–1.5×, applied once above the navigator |

`CupertinoTheme` resolves colours from a *light* system theme by default, so
`NexusCupertinoTheme` writes it once from the tokens in `MaterialApp`'s
builder, above the navigator, where every route inherits it. A Cupertino
control must never be the one surface that is the wrong colour.

**Composer** — `surfaceSecondary` pill, `radius 12`, no visible border, mic
inside at `textSecondary`, one circular accent send button with a tooltip.
Tap target ≥44pt.
