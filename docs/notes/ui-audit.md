# Nexus — UI audit

Read-only pass, 2026-10-08. No code changed. Files read: `lib/ui/*.dart`,
`lib/ui/components/nexus_ui.dart`, `lib/ui/design/tokens.dart`.

## 1. Every top-bar icon that exists

| # | File · line | Icon | Tooltip / label | What it does | Tests depend on it? |
|---|---|---|---|---|---|
| 1 | `assistant_view.dart:1928` | `Icons.psychology_alt_outlined` | "What I still misunderstand" | opens the dream-review sheet | **yes** — `assistant_playtest_test` taps it (×3) |
| 2 | `assistant_view.dart:1933` | `Icons.add_comment_outlined` | "New conversation" | resets the thread | **yes** — `assistant_view_test` taps it (×2) |
| 3 | `files_view.dart:449` | `Icons.folder_rounded` | — | decorative icon tile beside the "Files" title | no |
| 4 | `files_view.dart:523` | `Icons.arrow_upward_rounded` | "Up" | parent folder | no |
| 5 | `files_view.dart:530` | `Icons.home_rounded` | "Home" | device root | no |
| 6 | `files_view.dart:567` | `Icons.refresh_rounded` | "Refresh" | re-list the folder | no |
| 7 | `assistant_view.dart:1894` | `Icons.close_rounded` | "Not now" | dismisses the dream nudge | **yes** — `assistant_playtest_test` |

Rows 1–2 are the assistant's **header trailing actions** — the only two icons
that sit in the top bar of the screen users see first. Rows 4–6 are a
mid-screen Files toolbar, not a top bar. Row 3 is a decorative tile. Row 7 is
inside a card, not the bar.

`devices_view.dart`'s top bar is already clean: title + subtitle, no actions.
Its "Add device" is a labelled `FilledButton.icon` pinned to the bottom.
`settings_view.dart`'s top bar is title + subtitle, no actions.

**The two the user means are almost certainly rows 1–2.** Both are functional,
so removing them means relocating the functions, and both are tapped by tests,
so the tests move with them.

## 2. Screens and their current layout

| Screen | Frame | Header | Body | Reads as |
|---|---|---|---|---|
| Assistant | bare `Column` | `NexusPresence`: orb + "Nexus" + status line + **2 trailing icon buttons** | nudge/reminder cards, thread, suggestion chips, composer | intentional shape, but the header carries chrome it shouldn't |
| Devices | `NexusPage` | `NexusPageHeader` (title + subtitle) | reachability card, `NexusGroup` rows, empty state, pinned "Add device" | intentional |
| Files | bare `Column` | `NexusHeader` (**decorative icon tile** + title + subtitle) | device chips, dense toolbar, list | toolbar is the weakest screen |
| Settings | `NexusPage` | `NexusPageHeader` | section headers + `NexusGroup`/`NexusRow` | closest to Apple Settings already |

## 3. What looks "default Flutter" vs. intentional

**Intentional** (a real system, already built): `design/tokens.dart`
(`NexusPalette` light+dark, `NexusSpace`, `NexusRadius`, `NexusSize`,
`NexusType`, `NexusMotion`), `theme.dart` (builds `ThemeData` from the
tokens), `components/nexus_ui.dart` (`NexusPage`, `NexusPageHeader`,
`NexusSectionHeader`, `NexusGroup`, `NexusRow`, `NexusSwitchRow`,
`NexusStatusDot`, `NexusEmptyState`, `NexusPresence`, `NexusAsyncButton`),
`nexus_core.dart`, and the shell's phone-bar/desktop-rail split.

**Default-ish / off-system:**

| Where | What | Why it reads cheap |
|---|---|---|
| `assistant_view.dart` | hardcoded `EdgeInsets.fromLTRB(20, 10, 12, 0)`, `BorderRadius.circular(12)`, `fontSize: 13` in the nudge/reminder/welcome cards | the tokens exist and are ignored |
| `assistant_view.dart:3269` | `Colors.redAccent` literal | off-palette; `palette.danger` is the token |
| `assistant_view.dart` | `Material(color: Colors.transparent)` wrappers around InkWell | leftover from the Material pass |
| `files_view.dart` | `AlertDialog` with raw `TextStyle`, `NexusColors.*` dark-only literals, `Colors.white` on the delete button | dark-only, not appearance-aware |
| `devices_view.dart`, `files_view.dart`, `settings_view.dart` | still on the legacy **dark-only** `NexusColors` aliases rather than `NexusPalette.of(context)` | cannot follow light/dark; two colour systems in one app |
| all screens | no screen uses `Cupertino*` widgets; everything is Material 3 | fine on Android, but the "Apple" cues (rubber-band scroll, iOS back swipe, grouped inset lists) are absent |

## 4. The colour problem ("looks AI")

Two things carry the "AI product" signature:

1. **The accent.** One mint-teal (`#5EEAD4` dark / `#0E7490` light) with
   `accentStrong` `#2DD4BF`, used everywhere as a 10–16 % alpha wash
   (`accentTint`) behind chips, banners and the empty state. Mint-on-slate at
   low alpha is the house style of an AI startup, not of a shipped Apple app.
2. **The core.** `NexusCore` paints a glowing, ringed, latitude/longitude
   sphere that spins. It is honest about state, but a glowing orb in the header
   is itself the "AI" signifier.

There is no purple gradient anywhere — the AI read is the **tint washes plus
the glowing orb**, not a gradient.

## 5. UX rules that are actually broken

| Rule | Where it is broken |
|---|---|
| One prominent action per view | Files shows Up + Home + Send-file + Refresh + a `more_vert` menu at once |
| 44×44 minimum target | held (asserted by `accessibility_test`), but only just, via manual `minimumSize` patches |
| 8pt spacing grid | `NexusSpace` mixes 2/4/12/20/28 — off the 8 grid; assistant uses raw numbers anyway |
| Semantic colour, light + dark | three screens use dark-only `NexusColors`; light theme exists in tokens but no screen claims it |
| Style, not size, distinguishes hierarchy | ok — outlined/filled/text buttons are used with intent |
| Values right-aligned, chevrons on rows | Settings rows have **no chevrons** and no right-aligned values for the informational rows |

## 6. Scope for this pass

- Remove the assistant header's two icon buttons; relocate both functions.
- Restyle the assistant chrome onto the tokens (one accent, semantic colours,
  grid spacing) without touching logic.
- Leave Devices / Files / Settings for a follow-up pass, except for the
  shared token changes they inherit for free.
- Out of scope: Cupertino navigation widgets (would change behaviour and the
  nav tests), light-mode wiring, and the `NexusCore` orb.
