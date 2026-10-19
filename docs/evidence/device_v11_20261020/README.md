# v1.1 on the phone — 2026-10-20

Device: Samsung SM-A256E (Galaxy A25 5G), Android via USB debugging.
Build: `flutter build apk --debug`, installed over the previous build with
`adb install -r --no-streaming`. `flutter test`: 1513 passed, 3 skipped.

## What was checked

| Check | Result |
| --- | --- |
| Cold install and launch | Pass — no crash, thread and tabs restored |
| First-use contacts prompt | Pass — permission dialog appears on the first `call`; Allow grants `READ_CONTACTS` |
| Contact call | Pass — "call TVcraft01" resolves to the address-book entry and opens the dialer prefilled with `+33652544264` ([dialer_contact.png](dialer_contact.png)) |
| Missing contact | Pass — the "No contact named …" pill is shown, no dead end ([no_contact.png](no_contact.png)) |
| Live conversation handoff | Pass — the Live page opens from the composer, starts the on-device recognizer, and returns with X ([live_conversation.png](live_conversation.png)) |
| Voice language | Pass — the dropdown offers 11 languages, the choice applies to both speech seams and survives a relaunch; the label now updates immediately ([voice_language.png](voice_language.png)) |
| Chat persistence under rapid saves | Pass — no `PathNotFoundException` after the save queue fix |

## Fixes made from the device run

- **Chat file race** (`lib/core/chat_log.dart`): overlapping saves shared one
  `.tmp` path; the first rename won and the second logged a `PathNotFoundException`.
  Saves are now serialized through a queue, with a regression test that fires
  eight saves in one turn.
- **Dialer confirmation casing** (`lib/core/fast_path.dart`): the interpreter
  lower-cases phrases, so the phone echoed `tvcraft01` for "TVcraft01". The fast
  path now restores the spoken spelling when the resolved target is unchanged.
- **Language label** (`lib/main_ui.dart`): `_LanguageRow` read
  `VoiceSettings.language` without listening to the notifier, so the closed
  dropdown kept the old language until the page was reopened. It now listens and
  rebuilds on change.

## Not covered

- A real outbound call was not placed (the dialer was prefilled and left for the
  user to press Call).
- Speech recognition on this ROM reported `ERROR_LANGUAGE_UNAVAILABLE` (13) for
  en-US after opening the mic in a silent room; the on-device English model may
  not be installed. Worth a separate look at the on-device recognizer fallback.
