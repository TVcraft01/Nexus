# On-device verification — 2026-10-29, `R5CX73XFGKW`

First hardware check after seven passes of loopback-only work, against a release
build of the tree at `505aa69`. The PC is the paired peer, driven by
[`test/device_peer_probe.dart`](../../../test/device_peer_probe.dart), which
pairs with the phone's mesh from its QR payload and then speaks the control and
agent wires. Stages are hand-off files so the phone can be photographed between
them.

## The correction this file exists to record

An earlier draft of this file reported 3c as failing on hardware — no card, no
reply, sender timing out. **That conclusion was wrong, and for a reason worth
keeping:** the APK installed on the phone had been built at 22:51, twenty-one
minutes *before* `4baa1a3` (23:12) landed. The phone was running a build that
did not contain 3c at all. The feature was never on the device being tested.

Two lessons, both cheap to state and expensive to relearn:

1. A device check is only about the build it installed. Compare the APK's
   mtime against the commit before writing anything down.
2. The card renders at the top of the Devices list. The list was scrolled down
   in every screenshot taken while the card was present, so "no card" was a
   scrolled list, not a missing feature.

## Passed

### Notification permission (never verified before)

| Step | Result |
| --- | --- |
| First launch after install | `POST_NOTIFICATIONS` prompt shown (`01_permission_prompt.png`) |
| Decline, relaunch | Prompt shown once more — the documented 2-strike rule |
| Decline again, relaunch a third time | Silent (`02_permission_silent_after_two_denials.png`), `dumpsys` shows `user-fixed`, `granted=false` |

### 3a — signed control

| Step | Result |
| --- | --- |
| Unsigned ping from a paired id | 200, snackbar `Ping from Rehearsal PC (unverified)` (`03_ping_unsigned_badge.png`), log `NEXUS ping: Rehearsal PC <- probe-pc-1 (unverified)` |
| Signed ping, HMAC-SHA256 over `nexus/control/v1\|probe-pc-1\|nonce\|ts\|ping` with the pairing token | 200, snackbar `Ping from Rehearsal PC` with no badge (`04_ping_signed_no_badge.png`), log line has no `(unverified)` |
| Forged signature (wrong key) | 401 `control request not verified`, no notification, no log line |

### 3c — peer-initiated action

| Step | Result |
| --- | --- |
| Peer pairs by dialling the phone | `pair-request <- probe-pc-1 (code matched)` |
| `music.search`, `approval: approved`, policy default `ask` | Card at the top of Devices: `Rehearsal PC wants to: Music search` / `From a paired, verified device.` (`05_peer_action_card.png`), mesh log `peer action music.search from probe-pc-1 (ask, proven)` |
| **Run it here** | The phone plays the preview and answers in its own words; sender receives `succeeded` with `Playing "Hotline Bling" by Drake — a 30-second preview…` in 1.1 s. Phone shows `Rehearsal PC asked — …` (`06_peer_action_approved.png`) |
| **Refuse** | Sender receives `denied` carrying exactly `This device does not accept that action from paired peers.` Phone shows the same sentence in the line (`07_peer_action_refused.png`) |

`probe_log.txt` is the sender's side of the refused round.

## Not verified

- **3b derived control key:** the token-first rule is exercised above; the
  derived key (a pairing that never carried a token) is not, because the harness
  always holds the QR's token and no older APK was available for a mixed pair.
- **`auto` and `deny` policies:** only the default `ask` path was driven. Both
  are reachable from the same card and covered by loopback tests, not by this
  run.
- **Policy table persistence across relaunch.**
- One log line was added to the agent-action receive path to make this check
  possible (`NEXUS mesh: peer action … (ask, proven)`); the rest of the code is
  the tree at `505aa69`.
