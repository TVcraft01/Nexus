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
| `section` | 24 | vertical gap between two page sections |

## 3. Type

System font, four sizes carry the app. No ultralight; nothing below 11.5pt.

| Token | Size | Weight | Use |
|---|---|---|---|
| `display` | 26 | 700 | page title |
| `title` | 17 | 600 | card/sheet title, "Nexus" |
| `rowTitle` | 15 | 600 | list row title |
| `body` | 14 | 400 | body copy, row subtitle |
| `caption` | 12.5 | 400 | helper text |
| `overline` | 11.5 | 700, +0.8 | uppercase group label |
| `button` | 15 | 600 | button label |

## 4. Radius, size, motion, shadow

| Radius | Value | | Size | Value | | Motion | Value |
|---|---|---|---|---|---|---|---|
| `xs` | 6 | | `minTouch` | 48 | | `fast` | 120 ms |
| `md`/`row` | 12 | | `row` | 64 | | `base` | 220 ms |
| `lg`/`card` | 16 | | `rowCompact` | 52 | | `slow` | 320 ms |
| `xl` | 24 | | `button` | 48 | | `standard` | easeOutCubic |
| `sheet` | 20 (top) | | `field` | 52 | | `emphasized` | easeOutQuart |
| `pill` | 999 | | `readable` | 640 | | `settle` | easeInOut |

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

**Composer** — `surfaceSecondary` pill, `radius 12`, no visible border, mic
inside at `textSecondary`, one circular accent send button with a tooltip.
Tap target ≥44pt.
