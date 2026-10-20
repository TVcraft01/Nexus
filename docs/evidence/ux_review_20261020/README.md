# v1.0.0 review pass — device evidence

Screenshots from the SM-A256E (`R5CX73XFGKW`) after installing the build that
carries the review fixes. Each one is the claim it proves, taken on the phone
rather than in a widget test.

| Image | The claim |
|---|---|
| `settings_accent_ai_status.png` | The accent swatch is a rounded square like every other leading tile, and the AI row names the model: `On-Device AI: Qwen 2.5 (Loaded)`. The Voice section has no wake-word row. |
| `files_connected_devices.png` | The Files tab opens on `Connected Devices — None`, above the device picker. |
| `drawer_pinned_row.png` | A pinned chat sits above `TODAY` with a pin glyph and no "Pinned" heading. |
| `composer_speak_replies.png` | `Speak replies` is a speaker button beside the composer's `+`; the crop shows it switched off (crossed speaker). |
| `image_share_sheet.png` | "Share" on an image bubble opens Android's own share sheet with the image attached. |

Checked on the device and not photographed, because the evidence is a log line
or a system property rather than a picture:

* **Back closes the drawer** — swipe from the left edge (64 px), then `input
  keyevent 4`: the drawer closes and `mCurrentFocus` stays on
  `dev.nexus.nexus/.MainActivity`.
* **Media keys are real playback** — "play music" moved the phone's media track
  from `state:paused` to `state:started` in `dumpsys audio`, and "pause music"
  moved it back to `state:paused`, with "Playing." / "Paused." in the thread.
* **Weather is answered locally** — "weather" produced
  "I don't have internet access to check the weather. I am a local AI."
  without asking the model.
* **UI locale follows the voice language** — after choosing Français, the
  Material back button's tooltip read `Retour` and an empty thread greeted
  "Bonjour, comment puis-je aider ?". Restored to English (UK).
* **App icon picker** — choosing Light set `IconLight` enabled / `IconDark`
  disabled in `dumpsys package`; choosing Auto restored the dark mark on a dark
  phone.
* **Developer mode toggles** — seven taps on Version showed "Developer Mode
  Unlocked!" and added the Logs tab; seven more showed "Developer Mode Locked"
  and removed it.
* **Check for updates** — no chevron; the row showed its spinner and then
  "Nexus is up to date!" in a snack bar.
