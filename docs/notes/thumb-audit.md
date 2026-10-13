# Thumb-zone audit — phone (1080×2340 px, dpr 2.75 → 393×851 dp)

Bottom third: y > 1560 px (567 dp). Top third: y < 780 px (284 dp).
Minimum target: 48×48 dp (132×132 px). Minimum gap: 8 px (≈21 px device).
Feedback: visible response ≤ 100 ms after touch-*down*.
Positions below are source-derived estimates; the on-device pass re-measures
every changed control from a real uiautomator dump.

Conventions used in the verdicts: NexusPressable answers on touch-down via raw
pointer events (immediate). Material buttons answer on touch-down via InkWell
(immediate outside scrollables; inside a scrollable the gesture arena may hold
the highlight up to ~100 ms — marked ARENA). A bare GestureDetector answers
with nothing until the action lands — that is the failure this audit hunts.

## 1. Shell + tab bar (home_shell.dart)

| # | Control | Rect (dp, est.) | Primary? | Bottom 3rd? | Size ≥48? | Gap ≥8px? | Feedback | Verdict |
|---|---------|-----------------|----------|-------------|-----------|-----------|----------|---------|
| 1.1 | Tab bar: Assistant / Devices / Files / Settings | 4× ~98 wide, y ~787–851 | nav (primary nav) | YES | YES (≈64 tall) | n/a (edge-to-edge tabs, standard) | Cupertino immediate | PASS |
| 1.2 | UpdateBanner Later / Update & install | full-width row, y ~60–130 | secondary (rare, transient) | NO (top) | YES (48 tall) | 8+ between | InkWell/ARENA | PASS-EXC (system banners live top on both platforms; transient; dismissible) |

## 2. Assistant (assistant_view.dart)

| # | Control | Rect (dp, est.) | Primary? | Bottom 3rd? | Size ≥48? | Gap ≥8px? | Feedback | Verdict |
|---|---------|-----------------|----------|-------------|-----------|-----------|----------|---------|
| 2.1 | Composer mic IconButton | 48×48, bottom row | primary (voice ask) | YES | YES | — | InkWell down | PASS, gap see 2.3 |
| 2.2 | Composer send IconButton.filled | 48×48, bottom row | primary (send) | YES | YES | 4 px to mic | InkWell down | **FAIL spacing** (4 px mic→send) |
| 2.3 | Composer text field | full-width minus buttons | primary (type) | YES | YES (tall) | 0 px to mic | cursor/focus | NOTE (flush fields are the platform pattern; not changed) |
| 2.4 | Suggestion chips (ActionChip row) | 231×126 px = 84×48 dp (uiautomator) | primary (examples) | YES | YES, exactly 48 | 8 px | InkWell/ARENA | PASS (device overrules the stale 40 dp comment; comment corrected) |
| 2.5 | Header presence row (InkWell, long-press → menu) | full-width, y ~60 | secondary (menu) | NO | YES (tall) | n/a | long-press only, tap does nothing | **FAIL no tap equivalent** |
| 2.6 | Clipboard pill (GestureDetector) | full-width strip | secondary (paste) | YES | YES (tall) | n/a | NONE until paste lands | **FAIL feedback** |
| 2.7 | Fetched file card (GestureDetector) | full-width card | secondary (open) | in thread | YES (tall) | n/a | NONE until viewer opens | **FAIL feedback** |
| 2.8 | Brain status strip (NexusPressable) | full-width, thin | secondary (re-probe) | NO (top) | thin (~24 visual; pressable = row) | n/a | touch-down | PASS (status, not action; tap only re-probes) |
| 2.9 | Reminder banner Done IconButton | 48×48, above composer | primary (dismiss nudge) | YES | YES | 8+ | InkWell down | PASS |
| 2.10 | Teach affordance text link | ~200×26 | secondary | in thread | **NO (~26 tall)** | n/a | touch-down (pressable larger than text? no — wraps text) | **FAIL size** |
| 2.11 | Plan cards: Copy now / Send blink / Send to X / Approve / Deny | full-width buttons | primary (act) | in thread | YES (48) | 12 px | InkWell down | PASS |
| 2.12 | Teach dialog Cancel / Teach | dialog actions | primary (in dialog) | dialog | YES (platform) | platform | InkWell down | PASS |
| 2.13 | Dream sheet rows + Teach IconButton | rows + 48 icon | primary (in sheet) | sheet (bottom) | rows 52+, icon 48 | 8+ | pressable / InkWell | PASS |
| 2.14 | Onboarding Start + Set up TextButtons | full-width / row | primary (setup) | in flow | YES (48 min) | 8 | InkWell down | PASS |

## 3. Devices (devices_view.dart)

| # | Control | Rect (dp, est.) | Primary? | Bottom 3rd? | Size ≥48? | Gap ≥8px? | Feedback | Verdict |
|---|---------|-----------------|----------|-------------|-----------|-----------|----------|---------|
| 3.1 | Add device (pinned bottom, paired state) | full-width, above tab bar | primary | YES | YES (48+) | n/a | InkWell down | PASS |
| 3.2 | Pair another device (phone-only empty state, inline) | full-width, mid-screen | primary | **NO (middle)** | YES | n/a | InkWell down | **FAIL position** |
| 3.3 | Paired rows (NexusRow 64) | full-width | primary (open detail) | scrollable | YES (64) | n/a (stacked rows) | touch-down | PASS |
| 3.4 | Nearby rows + Pair tonal button | full-width row, ~70-wide button | primary (pair) | scrollable | row 64; button 40 tall? tonal min (0,48)→48 tall | 8 | touch-down row / InkWell | PASS |
| 3.5 | Graph nodes (92×~94 pressable) | graph area | primary (open detail) | scrollable | YES | spaced by layout | touch-down | PASS |
| 3.6 | Detail sheet: Rename / Advanced rows (52) | sheet | secondary | YES (sheet) | YES (52) | n/a | touch-down | PASS |
| 3.7 | Detail sheet: Forget device (full-width outline) | sheet bottom | primary (destructive) | YES | YES | n/a | InkWell down | PASS |
| 3.8 | Rename/Save + Forget confirm dialog actions | CupertinoAlertDialog | primary (in dialog) | dialog | YES (platform ~44+) | platform | Cupertino down | PASS |

## 4. Files (files_view.dart)

| # | Control | Rect (dp, est.) | Primary? | Bottom 3rd? | Size ≥48? | Gap ≥8px? | Feedback | Verdict |
|---|---------|-----------------|----------|-------------|-----------|-----------|----------|---------|
| 4.1 | File/folder rows (NexusRow 64, full-width) | list | primary (browse/fetch) | scrollable | YES (64) | n/a | touch-down | PASS |
| 4.2 | Grid tiles (NexusPressable, large) | grid | primary | scrollable | YES (large) | 8+ gutters | touch-down | PASS |
| 4.3 | Device chips (48 strip, pills) | below header | primary (switch device) | upper third, scrolls | YES (48 tall, wide) | 8 px | touch-down | PASS (position: picker, not action; scrolls away) |
| 4.4 | Send file… FilledButton | toolbar row, y ~400–450 | secondary (creation; rows are primary) | NO | YES (48) | 8 px to overflow | InkWell down | PASS-EXC (toolbar pattern like iOS Files; rows are the primary) |
| 4.5 | Overflow More IconButton | 126×126 px = 48×48 (uiautomator) | secondary | NO | YES (48) | **0 px to Send (source misread as 8)** | InkWell down | **FAIL spacing on device → FIXED (8 px SizedBox added)** |
| 4.6 | Breadcrumb crumbs (48 tall pressables) | toolbar row | secondary (nav) | NO | height YES; **width = text, <44 possible** | separators only | touch-down | **FAIL width (short names)** |
| 4.7 | Swipe verbs Rename/Delete (GestureDetector, 84×64) | revealed under row | primary (manage) | at row | YES (84×64) | shared edge | NONE (deliberate per comment) | **FAIL feedback** |
| 4.8 | Selection bar Download/Delete/More/Cancel | bottom bar above tabs | primary (batch) | YES | YES (48) | **0 px between** | InkWell down | **FAIL spacing** |
| 4.9 | Overflow/sort/row-action sheets | CupertinoActionSheet | primary (in sheet) | YES (sheet) | YES (platform 57) | platform | Cupertino down | PASS |
| 4.10 | Delete confirm dialog actions | CupertinoAlertDialog | primary (in dialog) | dialog | YES (platform) | platform | Cupertino down | PASS |
| 4.11 | Rename file dialog field + actions | dialog | primary (in dialog) | dialog | YES | platform | platform | PASS |
| 4.12 | Choose-destination sheet: Up, Choose here, device pills, folder rows | sheet | primary (in sheet) | YES (sheet) | YES (48/52) | 8+ | mixed down | PASS |
| 4.13 | Search field | toolbar | secondary | NO | n/a (field) | n/a | focus | PASS (field, not a target) |

## 5. Settings + About (settings_view.dart, about_view.dart)

| # | Control | Rect | Primary? | Bottom 3rd? | Size | Gap | Feedback | Verdict |
|---|---------|------|----------|-------------|------|-----|----------|---------|
| 5.1 | All NexusRows incl. switches (64/52, full-width) | scrollable list | primary | scrollable | YES | n/a | touch-down | PASS |
| 5.2 | About push (chevron row) + system back | list / nav bar | secondary | scrollable / top-left | YES / platform | n/a | touch-down / platform | PASS (back also via Android gesture) |
| 5.3 | About page: no controls | — | — | — | — | — | — | PASS (nothing to miss) |

## 6. Pairing (pair_sheet.dart, scan_qr_page.dart, cable_pair_page.dart)

| # | Control | Rect | Primary? | Bottom 3rd? | Size | Gap | Feedback | Verdict |
|---|---------|------|----------|-------------|------|-----|----------|---------|
| 6.1 | Sheet Back / Close IconButtons | sheet header (bottom-half sheet) | secondary nav | YES (sheet) | YES (48) | title between | InkWell down | PASS |
| 6.2 | Scan a QR code (tonal, full-width) | sheet | primary | YES (sheet) | YES | 8+ | InkWell/ARENA | PASS |
| 6.3 | More-ways rows (52) + Enter/Show/Cable rows | sheet | primary | YES (sheet) | YES (52) | n/a | touch-down | PASS |
| 6.4 | Copy code / Show a new code (full-width) | sheet | primary | YES (sheet) | YES | n/a | InkWell down | PASS |
| 6.5 | Enter-code fields + Scan-instead + Pair (full-width) | sheet | primary | YES (sheet) | fields tall, buttons 48 | 10–16 | InkWell down | PASS |
| 6.6 | Scan page: no on-screen actions (auto-scan; system/nav back) | full camera | none | — | — | — | — | PASS (nothing critical top-left; back via gesture) |
| 6.7 | Cable page AppBar back (desktop flow; phone shows guide text only) | top-left | secondary nav | NO | 48 | n/a | InkWell down | PASS (system back gesture is the thumb path; no phone actions on this page) |

## FAIL count (source audit)

- Position: 1 (3.2) + 1 noted-needs-measure (2.4 chips: size, not position)
- Size: 1 (2.10) + 1 conditional (4.6 crumb width) + 1 needs-measure (2.4)
- Spacing: 2 (2.2 composer 4 px, 4.8 selection bar 0 px)
- Feedback: 3 (2.6 pill, 2.7 fetched card, 4.7 swipe verbs)
- Tap-equivalent: 1 (2.5 header long-press menu)

Total: 8 FAIL source + 1 FAIL found on device (4.5, audit's own misread) + 1 NEEDS-MEASURE→PASS. No primary action lives in an app bar.
Navigation depth: ≤ 2 everywhere (Settings→About, Devices→detail, Files→destination, sheets).

## Device re-measure (420 dpi → dpr 2.625; 48 dp = 126 px; 8 px = 21 px)

| Control | Bounds (px) | Size (dp) | Bottom edge vs 1560 | Gap | Verdict |
|---|---|---|---|---|---|
| Chips (×4) | 231×126 | 84×48 | mid (scrollable row) | 8 px | PASS |
| Composer mic | 126×126 | 48×48 | bottom third | 0 px to field (NOTE), 21 px to Send | PASS (gap to Send fixed) |
| Composer send | 126×126 | 48×48 | bottom third | 21 px | PASS |
| Tab bar ×4 | 270×131 | 103×50 | 2214 (bottom) | edge-to-edge tabs | PASS |
| Graph peer node | 241×247 | 92×94 | mid (scrollable) | layout-spaced | PASS |
| Paired row | 996×173 | 379×66 | scrollable | stacked | PASS |
| Add device pinned | 996×126 | 379×48 | 2051 > 1560 | 32 px to tabs | PASS |
| Device chip (Files) | 350×126 | 133×48 | upper (scrolls) | 8 px | PASS |
| Send file… | 370×126 | 141×48 | upper toolbar | 0 px to More → 21 px after fix | FIXED |
| More (Files) | 126×126 | 48×48 | upper toolbar | see above | FIXED |
| Recent file row | 996×131 | 379×50 | scrollable | stacked | PASS |
| Try again | 348×126 | 132×48 | mid | n/a | PASS |
| Settings rows | 996×168–220 | 379×64–84 | scrollable | stacked | PASS |
