# Nexus QA playbook (for coding agents)

Read this before any UI or UX task. Goal: operate the app like a person, find what looks or feels wrong, fix it, and prove the fix. Rules for what "right" means are in `docs/UI_UX_RULES.md`.

## 0. Hard rules
- Never ask for, store or log passwords, tokens or 2FA codes. A person types them in a terminal.
- Phone: only the Nexus app. No other apps, no phone settings (except Trust), no deleting data, no signing in anywhere.
- Screenshots may show private data. Use seeded demo data. Keep images out of the repo and PRs. Describe issues in words in PRs.
- One branch and one PR per task from fresh `main`. Do not merge unless the task says so. Wait for ALL CI jobs.
- Fix UI and copy only. A change in behavior needs its own task. Product questions go in `docs/DECISIONS.md`.
- Never claim "works" without evidence (screenshot name, log line, file on disk, test output).

## 1. Run instances (PC)
- Use a **profile** build (`flutter build linux --profile`): the dev pairing gate is off in release builds.
- Every instance gets its own directories and environment:
  `HOME`, `NEXUS_DATA_DIR`, `XDG_DATA_HOME`, `NEXUS_SERVED_ROOT`, `NEXUS_DOWNLOADS_DIR`,
  plus `NEXUS_DEV_PAIR=1` and `NEXUS_CLIPBOARD_FILE=<path>` (its own fake clipboard).
  Example root: `~/nxs-pc/run/<name>/`. Seed a demo profile and `settings.pairingEnabled`. Never serve `$HOME`.
- Window 880 x 1000. Also test 360 px wide, light and dark, text scale 100% and 200%.
- Run one instance at a time for assistant tests: a second instance steals the PC-compute link.
- Pairing without a camera: instance A shows its QR, decode the payload from the screenshot (`zbarimg`), instance B uses **Pair by code** and types it.

## 2. Drive the UI like a user
- Use `tool/ui_driver.py` (grim for screenshots, tesseract OCR, uinput for clicks, wtype for typing).
- OCR on raw dark screenshots is poor. Enhance first: grayscale, 3x upscale, contrast. Plain-frame OCR reads some bars better. Try both.
- Some labels are unreadable to OCR (purple on dark, action sheets). Measure the coordinates once, write them in the script, and verify the outcome on disk or in the next screenshot.
- Swipes cannot be synthesized here. Use the app's own path: long press a row, then the selection bar (Rename, Delete).
- After every action take a screenshot and check the result. Do not chain blind clicks.

## 3. Screens to cover
Home, assistant (ask five commands), devices (paired, online, offline, nearby), pairing sheet (QR, by code), files (local, remote browse, rename, delete, download), clipboard banner and settings, theme switch, empty states, error states (peer closed, no sharing), first launch.
Each in light and dark, 880 and 360 px wide, 200% text. On the iPhone: the same screens, screenshots over USB when possible.

## 4. What to check on every screen (from the UI rules)
- Words: vocabulary table (device, Online/Offline, Pair), sentence case, verb + object buttons, errors that say why and what to do. No jargon (mesh, peer, node).
- Layout: overflow or clipping, overlapping, 48 dp targets, spacing, alignment, readable size, truncated text.
- States: loading, empty, error, offline, no permission all exist and make sense.
- Honesty: no control that does nothing, no demo data shown as real, no setting without effect.
- Contrast and color: 4.5:1, never color alone, dark and light equal.
- Consistency: same words and order on PC and phone.
- Feel: does anything surprise, confuse or annoy a person? Write it down even if no rule covers it.

## 5. The fix loop
1. Make a table: screen / issue / rule / severity (P0 broken, P1 clear violation, P2 polish) / evidence.
2. Fix P0 and P1, one commit per area. Keep each fix small.
3. Re-run the same steps, re-take the same screenshots, compare before and after (ImageMagick `compare -metric AE`). Expected differences only.
4. `flutter analyze --no-fatal-infos` (61 pre-existing infos is the baseline) and `flutter test` (the count must not drop).
5. Push, open the PR, wait for ALL CI, report: table, before/after for the 10 biggest fixes, the P2 list, and what was not tested.

## 6. Known facts and traps
- The shipped shell is `lib/main_ui.dart` (`settings_tab.dart` is a `part` of it). Check a screen is reachable before editing it: `settings_view.dart`, `home_shell.dart` and others are dead code.
- Source rule tested by `test/platform_gap_test.dart`: any "can't do that here" message uses `gapAnswer` and names where it works.
- Chips on the home screen are a random shuffle: do not report them as differences.
- Assistant wording is model-generated and varies between runs: compare behavior, not exact text.
- Two instances on one host share the OS clipboard: use `NEXUS_CLIPBOARD_FILE`.
- Deny a pairing: only the QR-request path has Allow/Deny.
- iPhone build: installed id is `XTL-<team>.dev.nexus.nexus` (xtool prefixes it). Free Apple ID certificates expire after 7 days. The iPhone is a light device: no wake word, no local model, no background sync. Android keeps ML Kit and Apple Vision runs on iOS.
- `gh` works again. If it hangs, the real binary is under `~/.local/share/mise/installs/gh/`.
