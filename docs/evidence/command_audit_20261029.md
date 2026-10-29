# Command audit — 2026-10-29

Not a feature pass. The interpreter and the launched shell were tested the way
a person uses them: every action the assistant can take, several phrasings per
action, and twenty-two sentences typed into the real composer.

Three things came out of it:

1. a coverage matrix over all 69 `AgentActions` ids,
2. an inventive corpus of 168 must-pass phrasings (plus the gaps and the
   must-not-match set),
3. a critic's run through the launched shell, with the complaints a user would
   actually make.

Cheap fixes were applied. Everything structural is named here with the pass
that should close it.

---

## 1 — Coverage matrix

69 actions in `lib/core/agent_contract.dart`. Before this pass one of them —
`music.play` — was named by no test at all.

Verdicts:

- **PARSED** — a phrase in `test/command_inventive_test.dart` reaches this id,
  and that phrase is asserted, not skipped.
- **DEVICE-CHANNEL** — a real capability that the phrase grammar never emits;
  it travels on the device channel. Covered by asserting what it says.
- **NEVER-EMITTED** — declared in the contract, unreachable from any phrase.

Totals: **67 PARSED, 1 DEVICE-CHANNEL (`music.play`), 1 NEVER-EMITTED
(`currency.get`), 0 untested.**

| action id | constant | verdict | exercised by |
| --- | --- | --- | --- |
| `device.list` | `deviceList` | PARSED | agent_contract_test.dart, capability_test.dart, command_interpreter_test.dart |
| `led.blink` | `ledBlink` | PARSED | agent_contract_test.dart, capability_test.dart, command_interpreter_test.dart |
| `greet` | `greet` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `time.get` | `timeGet` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `math.calc` | `mathCalc` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `help.get` | `helpGet` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `clipboard.write` | `clipboardWrite` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `search.web` | `webSearch` | PARSED | assistant_view_test.dart, capability_test.dart, command_interpreter_test.dart |
| `note.create` | `noteCreate` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `timer.set` | `timerSet` | PARSED | assistant_view_test.dart, capability_test.dart, command_interpreter_test.dart |
| `open.url` | `openUrl` | PARSED | capability_test.dart, command_inventive_test.dart, command_service_test.dart |
| `system.info` | `systemInfo` | PARSED | capability_test.dart, command_inventive_test.dart, intent_test.dart |
| `device.volume` | `volumeSet` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `app.open` | `appOpen` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `app.close` | `appClose` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `device.screenshot` | `screenshot` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `device.battery` | `batteryGet` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `device.brightness` | `brightnessSet` | PARSED | capability_test.dart, command_inventive_test.dart, command_surface_test.dart |
| `device.flashlight` | `flashlightToggle` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `device.airplane` | `airplaneModeSet` | PARSED | capability_test.dart, command_inventive_test.dart, command_surface_test.dart |
| `device.wifi` | `wifiToggle` | PARSED | capability_test.dart, command_inventive_test.dart, command_surface_test.dart |
| `device.bluetooth` | `bluetoothToggle` | PARSED | capability_test.dart, command_inventive_test.dart, command_surface_test.dart |
| `device.lock` | `lockScreen` | PARSED | capability_test.dart, command_inventive_test.dart, command_surface_test.dart |
| `device.restart` | `deviceRestart` | PARSED | capability_test.dart, command_inventive_test.dart, command_surface_test.dart |
| `comm.call` | `callPlace` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `comm.message` | `messageSend` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `comm.email` | `emailSend` | PARSED | capability_test.dart, command_inventive_test.dart, command_service_test.dart |
| `media.play` | `mediaPlay` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `music.play` | `musicPlay` | DEVICE-CHANNEL | device_actions_test.dart |
| `media.pause` | `mediaPause` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `media.next` | `mediaNext` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `media.prev` | `mediaPrev` | PARSED | capability_test.dart, command_inventive_test.dart, command_surface_test.dart |
| `media.shuffle` | `mediaShuffle` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `media.repeat` | `mediaRepeat` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `alarm.set` | `alarmSet` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `alarm.dismiss` | `alarmDismiss` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `alarm.show` | `alarmShow` | PARSED | command_inventive_test.dart, system_actions_test.dart |
| `timer.status` | `timerStatus` | PARSED | capability_test.dart, command_inventive_test.dart |
| `timer.cancel` | `timerCancel` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `reminder.set` | `reminderSet` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `weather.get` | `weatherGet` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `nav.open` | `navOpen` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `location.get` | `locationGet` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `intro` | `intro` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `music.search` | `musicSearch` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `currency.get` | `currencyGet` | NEVER-EMITTED | capability_test.dart, command_inventive_test.dart, command_surface_test.dart |
| `timezone.get` | `timezoneGet` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `calendar.add` | `calendarAdd` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `calendar.read` | `calendarRead` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `assistant.appDefault` | `appDefault` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `profile.set` | `profileSet` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `profile.get` | `profileGet` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `note.shopping.add` | `shoppingListAdd` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `note.shopping.get` | `shoppingListGet` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `display.dark` | `darkModeSet` | PARSED | capability_test.dart, command_inventive_test.dart |
| `define.word` | `defineWord` | PARSED | capability_test.dart, command_inventive_test.dart, command_surface_test.dart |
| `translate.text` | `translateText` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `convert.unit` | `unitConvert` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `random.dice` | `randomDice` | PARSED | capability_test.dart, command_inventive_test.dart, command_surface_test.dart |
| `random.coin` | `randomCoin` | PARSED | capability_test.dart, command_inventive_test.dart, command_surface_test.dart |
| `random.number` | `randomNumber` | PARSED | capability_test.dart, command_inventive_test.dart, command_surface_test.dart |
| `tell.joke` | `tellJoke` | PARSED | capability_test.dart, command_inventive_test.dart, command_surface_test.dart |
| `memory.remember` | `memoryRemember` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `memory.recall` | `memoryRecall` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `memory.forget` | `memoryForget` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `memory.question` | `memoryQuestion` | PARSED | capability_test.dart, command_interpreter_test.dart, command_inventive_test.dart |
| `device.find` | `findDevice` | PARSED | capability_test.dart, command_inventive_test.dart, command_surface_test.dart |
| `device.ring` | `ringDevice` | PARSED | capability_test.dart, command_inventive_test.dart, command_surface_test.dart |
| `file.fetch` | `fileFetch` | PARSED | assistant_view_test.dart, capability_test.dart, command_interpreter_test.dart |

### What the two exceptions mean

`music.play` is honest as a device capability: a peer that was asked to play
opens its own player, so the id arrives over the device channel rather than
from a sentence. `test/device_actions_test.dart` now asserts the id and the
words it is described with.

`currency.get` is not honest. The interpreter never emits it — "convert 100 usd
to eur" and "how much is 100 usd in eur" both resolve to `convert.unit` — so it
is a contract entry with no route to it. Either the exchange-rate question gets
its own pattern, or the action is deleted. **Structural: 4e.**

---

## 2 — The inventive corpus

`test/command_inventive_test.dart`, grouped by category so a failure names the
kind of failure it is.

| category | entries | shape |
| --- | --- | --- |
| A — must match | 168 | a real phrasing; asserted to reach a named action |
| B — known gap | 21 | should be understood, is not; `skip:`d with the reason |
| C — must not match | 13 | garbage, fragments, hostile; asserted to reach *no* action |
| D — must ask, acts anyway | 2 | compound sentences; first verb wins today |

A covers 67 of 69 actions. It found two classes of breakage, both fixed in this
pass (section 4). It found no failures in C: none of the thirteen reaches an
action.

### B — the 21 gaps, by pass

| phrase | should reach | why it does not | pass |
| --- | --- | --- | --- |
| `quelle heure est-il` / `quelle heure il est` | `time.get` | French time is not in the phrase list | 4e |
| `mets un minuteur de 5 minutes` | `timer.set` | French timer verb | 4e |
| `appelle maman` / `envoie un texto a maman` | `comm.call` / `comm.message` | French comm verbs | 4e |
| `quel temps fait-il a paris` | `weather.get` | French weather (the other forms work) | 4e |
| `allume la lampe torche` | `device.flashlight` | French device verbs | 4e |
| `quel est mon niveau de batterie` | `device.battery` | French battery | 4e |
| `put on some jazz` | `music.search` | "put on" is musical, not lexical — "put on my shoes" would open a search | 4e |
| `hey nexus what time is it` | `time.get` | wake-word filler in front of a phrase | 4e |
| `ok so set a timer for 5 minutes please` | `timer.set` | leading filler and trailing politeness | 4e |
| `light on` / `timer 5 minutes` / `alarm 7am` | flashlight / timer / alarm | word order the grammar does not have | 4e |
| `hey there` | `greet` | greeting is a one-word list | 4e |
| `add lunch tomorrow at noon` | `calendar.add` | calendar write requires a "… to my calendar" tail | 4e |
| `schedule a meeting tomorrow at 3` | `calendar.add` | **reads** the calendar instead of writing to it | 4e |
| `usd to eur` / `what is the exchange rate` | `currency.get` | no route to the action; the second is answered out of memory | 4e |
| `read my shopping list` | `note.shopping.get` | exact phrase list, and this form is not on it | 4e |
| `which app should i use` | `assistant.appDefault` | defaults are set by "use X for music", never suggested | 4e |

### D — sentences that name a command and then keep going

`call mom on facetime on my phone via whatsapp` places the call, silently
dropping two of the three connectors. `text mom saying hi and also email dad …`
sends the text. Both are skipped rather than asserted, because the current
answer is not "nothing" — it is the first verb, with the rest of the sentence
discarded. Whether that is right is a design question, not a parser bug.
**3d/4e.**

---

## 3 — The critic's run

Twenty-two sentences through the launched shell (`test/command_critic_test.dart`),
covering one per family plus hostile, empty, French and voice-glued input.
Every one is accepted by the composer, produces no exception, and leaves the
user's own words in the conversation.

Ten of the twenty-two are answered without the model. The complaints, ranked:

1. **The same sentence gets opposite answers on the two surfaces.** "what is the
   weather in paris" through the legacy `AssistantView` reaches `localAnswer`
   ([answers.dart:1091](lib/core/answers.dart#L1091)) and says *"Checking the
   weather in Paris…"* with a real fetch behind it. The same sentence typed into
   the launched shell hits `fastPathReply` ([fast_path.dart:76](lib/core/fast_path.dart#L76))
   and says **"I need internet access to check the weather. I am a local AI."**
   One query, one app, two answers — a refusal on the surface a user actually
   uses, where the other surface would answer. `play hotline bling` is the same
   shape: the legacy path opens a search, the shell asks the model. This is a
   real bug, and it is worse than the complaint it replaced, because nothing in
   the shell looks broken — it answers, confidently, with the wrong answer.
   **Structural: 3e (one answer owner).**
2. **A verb with nothing after it invented content.** "note that" created a
   note whose text was `that`; "search for" searched for `for`; "remind me to"
   set a reminder about `to`; "blink the" blinked a node named `the`. Fixed
   this pass (section 4) — the four sites shared one cause.
3. **Sentences that parse cleanly and then run nothing.** This entry replaces an
   earlier claim that the composer never asks the parser. It does —
   [home_tab.dart:872-916](lib/ui/home_tab.dart#L872-L916) runs the clock, the
   canned weather line, arithmetic, and `fastPathAction` before the model is
   asked. Measured over the critic's own 22 sentences: **10 run without the
   model** (time, math, flashlight, wifi, open app, alarm, timer, call, text,
   battery), and 13 reach it. Of those 13, **7 are read correctly and dropped for
   want of an executor** — `note that buy milk`, `add eggs to my shopping list`,
   `remember that my bike code is 4321`, `who is mom`, `play hotline bling`,
   `get report.pdf from my pc`, `search for cats`. That is not a parsing gap and
   not 3d vocabulary: `actionFromPhrase` only speaks the closed
   `SystemActionCall` list, and the layer that runs everything else is
   `CommandService` + `localAnswer`, which the launched shell has never
   constructed (`CommandService(` appears in `assistant_view.dart:402` and
   nowhere else). **Structural: 3e (the executor, not the parser).**
4. **The calendar writes when it should read, and cannot write when it
   should.** "schedule a meeting tomorrow at 3" returns the day's events;
   "add lunch tomorrow at noon" is not understood at all. The only working write
   is "… to my calendar". **Structural: 4e.**
5. **Currency questions land somewhere else.** "what is the exchange rate" is
   answered as a memory question — a confident answer to a different question.
   **Structural: 4e.**
6. **French is thin.** Eight everyday sentences fail; the media verbs are the
   only French family that works end to end. **Structural: 4e.**

Two more, lower:

- Voice glue survives only sometimes: "Getreport.pdf from my PC" works
  (capitalisation and no space are handled), "hey nexus what time is it" does
  not (filler is not).
- Two verbs are answered by lists rather than grammar: `greet` and the clock
  app's pages. "hey there" and "what alarms do i have" were each one word away
  from working; both are fixed below, and the shape is worth remembering when
  the next one is added.

---

## 4 — Triage, and what was fixed

Cheap: one helper, a handful of phrase-list entries, one production file.

| failure | fix | files |
| --- | --- | --- |
| "note that" / "search for" / "remind me to" / "blink the" ran with the connective as content | `_contentWithoutConnective` — strip a lone connective, and treat the empty result as `unknown` | `command_interpreter.dart` (4 sites) |
| "what can you help me with" | one phrase entry | `command_interpreter.dart` |
| "how long is left", "how long is left on the timer", "time left on the timer" | `timer.status` phrase list | `command_interpreter.dart` |
| "cancel my timer", "stop my timer", "end my timer" | `timer.cancel` phrase list | `command_interpreter.dart` |
| "list alarms", "list my alarms", "what alarms do i have", "what alarms do i have set" | `alarm.show` phrase list | `command_interpreter.dart` |
| "dismiss alarm", "turn off alarm" | `alarm.dismiss` phrase list | `command_interpreter.dart` |
| `music.play` had no test at all | a test asserting the id and its description | `device_actions_test.dart` |

Thirteen phrase entries and one helper. No existing test changed, none broke.
The suite was 1961 passing / 19 skipped before the audit's own three files
were counted and 2015 passing / 26 skipped on the final tree — the 26 skips
are this pass's own category B and D entries plus the three that were
already there.

Structural, left alone and named for the next pass:

- **3e** — one answer owner across the two surfaces (complaint 1), and an
  executor on the launched path for the seven sentences that parse and are
  dropped (complaint 3); the compound-sentence question (category D).
- **4e** — calendar writes without the "… to my calendar" tail and the
  read/write misroute; currency (`currency.get` has no route); the
  twenty-one B entries, mostly French and filler; word-order forms.

---

## 5 — What is protected from here

- `test/command_coverage_test.dart` reads `AgentActions` out of the source and
  the test directory off disk, and fails when an action arrives with no test.
  It is deliberately weak — "named somewhere in test/" is not "asserted to
  parse" — because its job is to make the silent addition loud. `music.play`
  and `alarm.show` are the two that reached main under the old silence.
- `test/command_inventive_test.dart` — the corpus. Category A fails the build;
  B is skipped with a reason that names the closing pass.
- `test/command_critic_test.dart` — the sentences, through the real shell. It
  proves the composer takes them and nothing throws. It does **not** assert
  that each one ran: on the test host the phone-only actions are filtered out
  by platform, and the seven parsed-but-executorless sentences have nothing to
  run. What runs where is measured in section 3, not asserted here.

---

## adb

Attempted once this pass, as required. Discovery is alive —
`adb mdns services` advertised `adb-R5CX73XFGKW` at `192.168.1.8:33999` — but
`adb connect` was refused (wireless-debugging ports rotate when the phone's
pairing screen is reopened), so there is no device attached and nothing in this
report was verified on hardware. Everything above is loopback and unit-level.
