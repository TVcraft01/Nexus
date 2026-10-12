# Voice: the spoken loop, on real hardware — 2026-10-11

Recording: [voice_spoken_demo.mov](voice_spoken_demo.mov) (1.9 MB, 1080×2340,
180 s), pulled from the phone's `/sdcard/voice5.mov`. Phone: R5CX73XFGKW.

## How it was verified (headless)

The video was never watched — frames were extracted with `ffmpeg` (1 per
20 s) and read with `tesseract` OCR on the PC. Every sampled frame shows
the Nexus assistant thread; the key frames show:

- `Listening — say it when you are ready` — the voice loop armed, mic open.
- `I don't understand "ge" yet` — a clipped live utterance reaching the
  interpreter as speech, not typing.
- `get report.pdf` / `Done` / `Saved report.pdf from Rehearsal PC to
  /storage/emulated/0/Download/report.pdf` — the fetch completing on the
  phone, paired (`Ready — all 1 devices reachable`).

Corroboration: `/sdcard/Download/report.pdf` (4096 bytes) is stamped
2026-10-11 17:38, minutes after this recording (17:11). The next recording
(`voice7.mov`, 17:20–17:22) shows a different, failed attempt (`call mom` →
`No contact named "mom"`), so this file, not that one, is the run.

## Honest limits

- Recorded 2026-10-11 ~17:11 CEST (~26 h before it was committed) — no
  recording from the last 6 hours exists on the PC or the phone, so the
  recency heuristic in the mission brief could not be met. This is the most
  recent successful voice-loop run on disk.
- Frame sampling (1/20 s) can miss transient states: the full spoken
  transcript of the fetch sentence is not visible in the sampled frames,
  only its clipped `ge` fragment. What the frames prove is the loop armed,
  live speech entering the pipeline, and the fetch Done card on real
  hardware — not one unbroken utterance end to end.
- Audibility of the spoken confirmation is still unclaimed (no ears here).
