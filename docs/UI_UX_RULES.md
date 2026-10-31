# Nexus UI and UX rules

Strict rules for every screen, dialog and string. A change that breaks a MUST is a bug.
Grounded in Material Design 3, Apple Human Interface Guidelines and WCAG 2.2 AA.
Where they disagree, Nexus follows the stricter rule.

## 1. Principles
1. **Honest.** The screen shows what is true now. Never show a control that does nothing, a setting with no effect, or demo data as if it were real.
2. **Consent first.** Anything that shares, reads, or changes something on another device asks the person who owns that device.
3. **Calm.** One primary action per screen. No nagging, no dark patterns.
4. **Same everywhere.** Phone and PC use the same words, same icons, same order.

## 2. Copy

### Voice
Plain, warm, short. Say what happened and what to do. No jargon (never "mesh", "peer", "node", "socket" in the UI), no blame, no jokes in errors.

### Vocabulary (one word per idea, everywhere)
| Use | Never |
|---|---|
| device | peer, node, endpoint |
| paired device | trusted node, linked peer |
| Online / Offline | Connected, Reachable, Up |
| Pair / Unpair | Link, Bond, Forget (except "Forget this device" confirm) |
| Nearby | Discovered, Heard |
| Send / Receive | Push / Pull |
| Nexus | the app, the system, the AI (when it speaks, it says "I") |

### Rules
- **Sentence case** for everything: titles, buttons, tabs, menus, dialogs. Capitalize only the first word and proper nouns (Nexus, Wi-Fi, Bluetooth, Android, Linux).
- **Buttons:** verb + object, 1 to 3 words, never "OK", "Submit", "Yes/No", "Click here". "Delete file", "Allow", "Not now".
- **Titles:** 2 to 5 words, no period. **Body:** 8 to 14 words per sentence, 20 at most, active voice, second person ("you").
- **Errors:** what failed, why, what to do. 12 to 18 words. Never "Something went wrong", "Error 403", or "Invalid".
  - Good: "Couldn't reach Kit. It may be asleep or on another network. Check Wi-Fi and try again."
- **Success:** past tense, specific: "File sent to Kit". Auto-dismiss after 4 seconds.
- **Empty states:** say why it's empty and give one action: "No paired devices yet. Pair a device to share files."
- **Permissions:** benefit first, then ask: "See your files on other devices. Allow file access."
- **Destructive actions:** the button repeats the verb and the object ("Delete 3 files"), the cancel is "Cancel", the dialog says whether it can be undone.
- **Loading** over 1 second: say what is loading ("Finding nearby devices"). Over 10 seconds: offer Cancel.
- **Numbers and time:** use the device locale, relative time under a day ("2 min ago"), no raw timestamps, no stack traces, no ids in user-facing text.
- **Every string** fits at 200% text size and in a language 40% longer than English without clipping. Plan for translation: no concatenated sentences.

## 3. Layout and components
- **Touch targets** at least 48 x 48 dp on phone (Material), 44 pt equivalent (Apple), 24 px minimum on desktop (WCAG 2.2). Spacing between targets at least 8 dp.
- **Spacing** on an 8 dp grid (4 dp for tight pairs). One spacing scale, no magic numbers.
- **Type:** use the theme text styles only. Body at least 14 sp. No more than 3 sizes per screen.
- **One primary button per screen or dialog.** Secondary actions are text or outlined buttons. Destructive actions are never the default focus.
- **Navigation:** at most 5 top-level tabs, same order on phone and PC, current tab always visible. Back always works and never loses typed input silently.
- **Lists:** consistent row anatomy (icon, title, one-line subtitle, trailing state). Truncate with an ellipsis, never overflow.
- **Responsive:** phone portrait and landscape, tablet, and desktop windows from 360 px wide. No horizontal scrolling, no clipped or overlapping widgets (zero RenderFlex overflow warnings).
- **Icons:** one icon style, one meaning per icon. An icon alone needs a text label or tooltip.

## 4. Color, contrast, motion
- **Contrast** at least 4.5:1 for text, 3:1 for large text and icons. Check both light and dark themes.
- **Never color alone.** Online/Offline, errors and success always pair color with an icon or a word.
- **Dark and light** themes have identical content and layout. Follow system by default and remember the choice.
- **Motion** 150 to 300 ms, purposeful only. Respect the system "reduce motion" setting.

## 5. States (every screen needs all of them)
Loading, empty, error, offline, and "no permission". A screen missing one of these is unfinished.
- Offline is a normal state, not an error: say what still works.
- A failed action always offers retry or a way out. No dead ends.

## 6. Accessibility
- Every control has a semantic label that reads well alone ("Delete report.txt", not "Delete").
- Reading order matches visual order. Focus order is logical, and keyboard and Tab navigation works on desktop with a visible focus ring.
- Works at 200% text scale and with a screen reader (TalkBack, Orca).
- Error text is announced and linked to its field.

## 7. Privacy and safety UI
- Show who is asking and what for ("Kit wants to open your Documents folder").
- Sharing switches show their current state in plain words and are off by default.
- A setting that doesn't work yet is not shown. "Coming soon" is the only allowed placeholder, and only where a user would otherwise look for it.
- Nothing changes on another device without an approval on that device, and every change can be undone.

## 8. Review checklist (use before every UI PR)
- [ ] All strings follow section 2 and the vocabulary table.
- [ ] No control without an effect, no demo data presented as real.
- [ ] Loading, empty, error and offline states exist.
- [ ] 48 dp targets, 4.5:1 contrast, no overflow at 360 px and at 200% text.
- [ ] Light and dark checked.
- [ ] Semantic labels on every control.
- [ ] Phone and PC show the same words and order.
