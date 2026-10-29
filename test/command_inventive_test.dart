// The inventive corpus: what a person actually types, mapped to the action it
// must reach.
//
// Categories, and why each is shaped the way it is:
//
//   A — `kMustMatch`. A real phrasing a person would use. If one of these
//       fails, the parser is wrong or the phrase is not as real as it looked;
//       the fix belongs in the parser, never in a weaker assertion here.
//
//   B — `kKnownGaps`. Phrases that *should* be understood and are not. They
//       are `skip:`d with a reason naming the gap rather than asserted to
//       match, because a red suite that everyone learns to ignore is worse
//       than a named gap. Each one is a bug-list entry; every reason starts
//       with the pass that should close it.
//
//   C — `kMustNotMatch`. Garbage, hostile multi-connector sentences, and
//       fragments that name a family but not a command. None of these may
//       reach an action: guessing here is how "call mom on facetime on my
//       phone via whatsapp" places a phone call.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/command_interpreter.dart';

typedef Phrase = ({String phrase, String action});

const List<Phrase> kMustMatch = <Phrase>[
  // --- the catalog's own examples, verbatim -------------------------------
  (phrase: 'show my devices', action: 'device.list'),
  (phrase: 'what time is it', action: 'time.get'),
  (phrase: '12 times 5', action: 'math.calc'),
  (phrase: 'what can you do', action: 'help.get'),
  (phrase: 'search for cats', action: 'search.web'),
  (phrase: 'note that buy milk', action: 'note.create'),
  (phrase: 'set a timer for 5 minutes', action: 'timer.set'),
  (phrase: 'open github.com', action: 'open.url'),
  (phrase: 'system info', action: 'system.info'),
  (phrase: 'volume up', action: 'device.volume'),
  (phrase: 'open youtube', action: 'app.open'),
  (phrase: 'flashlight on', action: 'device.flashlight'),
  (phrase: 'call mom', action: 'comm.call'),
  (phrase: 'text mom saying hi', action: 'comm.message'),
  (phrase: 'email mom saying hi', action: 'comm.email'),
  (phrase: 'play music', action: 'media.play'),
  (phrase: 'set an alarm for 7am', action: 'alarm.set'),
  (phrase: 'remind me to buy milk', action: 'reminder.set'),
  (phrase: 'take me home', action: 'nav.open'),
  (phrase: 'add milk to my shopping list', action: 'note.shopping.add'),
  (phrase: 'get report.pdf from my pc', action: 'file.fetch'),
  (phrase: 'what do you know about me', action: 'memory.recall'),
  (phrase: 'who is mom', action: 'memory.question'),

  // --- time ----------------------------------------------------------------
  (phrase: 'what time is it?', action: 'time.get'),
  (phrase: "what's the time", action: 'time.get'),
  (phrase: 'whats the time', action: 'time.get'),
  (phrase: 'hey, what time is it', action: 'time.get'),
  (phrase: 'can you tell me the time', action: 'time.get'),
  (phrase: 'what time is it right now', action: 'time.get'),

  // --- math ----------------------------------------------------------------
  (phrase: '2 + 3', action: 'math.calc'),
  (phrase: 'what is 12 times 8', action: 'math.calc'),
  (phrase: 'what is 15% of 80', action: 'math.calc'),
  (phrase: '12x5', action: 'math.calc'),
  (phrase: 'what is 12 * 5', action: 'math.calc'),

  // --- devices -------------------------------------------------------------
  (phrase: 'show my devices', action: 'device.list'),
  (phrase: 'list devices', action: 'device.list'),
  (phrase: 'what devices do I have', action: 'device.list'),
  (phrase: 'which are my devices', action: 'device.list'),
  (phrase: 'devices', action: 'device.list'),

  // --- help ----------------------------------------------------------------
  (phrase: 'what can you do?', action: 'help.get'),
  (phrase: 'help', action: 'help.get'),
  (phrase: 'what can you help me with', action: 'help.get'),

  // --- web -----------------------------------------------------------------
  (phrase: 'search for cats', action: 'search.web'),
  (phrase: 'search the web for cats', action: 'search.web'),
  (phrase: 'google cats', action: 'search.web'),
  (phrase: 'look up cats', action: 'search.web'),

  // --- clipboard -----------------------------------------------------------
  (phrase: 'copy hello to my devices', action: 'clipboard.write'),
  (phrase: 'copy hello', action: 'clipboard.write'),

  // --- notes, shopping, memory --------------------------------------------
  (phrase: 'note that buy milk', action: 'note.create'),
  (phrase: 'note down buy milk', action: 'note.create'),
  (phrase: 'add milk to my shopping list', action: 'note.shopping.add'),
  (phrase: 'add eggs to my shopping list', action: 'note.shopping.add'),
  (phrase: 'remember that my bike code is 4321', action: 'memory.remember'),
  (phrase: 'what do you know about me', action: 'memory.recall'),
  (phrase: 'who is mom', action: 'memory.question'),

  // --- timers, alarms, reminders ------------------------------------------
  (phrase: 'set a timer for 5 minutes', action: 'timer.set'),
  (phrase: 'set a timer for 10 minutes', action: 'timer.set'),
  (phrase: 'timer for 2 minutes', action: 'timer.set'),
  (phrase: 'set an alarm for 7am', action: 'alarm.set'),
  (phrase: 'alarm for 7am', action: 'alarm.set'),
  (phrase: 'remind me to buy milk', action: 'reminder.set'),
  (phrase: 'remind me to call the landlord at 5pm', action: 'reminder.set'),

  // --- media ---------------------------------------------------------------
  (phrase: 'play music', action: 'media.play'),
  (phrase: 'play my playlist', action: 'media.play'),
  (phrase: 'pause', action: 'media.pause'),
  (phrase: 'next', action: 'media.next'),
  (phrase: 'previous', action: 'media.prev'),
  (phrase: 'shuffle', action: 'media.shuffle'),
  (phrase: 'repeat', action: 'media.repeat'),
  (phrase: 'play hotline bling', action: 'music.search'),
  (phrase: 'play chill vibes', action: 'music.search'),
  (phrase: 'play Hotline Bling by Drake', action: 'music.search'),

  // --- communication ------------------------------------------------------
  (phrase: 'call mom', action: 'comm.call'),
  (phrase: 'call dad', action: 'comm.call'),
  (phrase: 'text mom saying hi', action: 'comm.message'),
  (phrase: 'text dad saying hello', action: 'comm.message'),
  (phrase: 'send a text to mom saying hi', action: 'comm.message'),
  (phrase: 'email mom saying hi', action: 'comm.email'),
  (phrase: 'email mom saying hello', action: 'comm.email'),

  // --- device control -----------------------------------------------------
  (phrase: 'volume up', action: 'device.volume'),
  (phrase: 'volume down', action: 'device.volume'),
  (phrase: 'mute', action: 'device.volume'),
  (phrase: 'set volume to 50', action: 'device.volume'),
  (phrase: 'brightness 50', action: 'device.brightness'),
  (phrase: 'flashlight on', action: 'device.flashlight'),
  (phrase: 'flashlight off', action: 'device.flashlight'),
  (phrase: 'turn on the flashlight', action: 'device.flashlight'),
  (phrase: 'wifi on', action: 'device.wifi'),
  (phrase: 'wifi off', action: 'device.wifi'),
  (phrase: 'bluetooth off', action: 'device.bluetooth'),
  (phrase: 'bluetooth on', action: 'device.bluetooth'),
  (phrase: 'lock screen', action: 'device.lock'),
  (phrase: 'screenshot', action: 'device.screenshot'),
  (phrase: 'battery', action: 'device.battery'),
  (phrase: 'system info', action: 'system.info'),

  // --- apps and links -----------------------------------------------------
  (phrase: 'open youtube', action: 'app.open'),
  (phrase: 'open spotify', action: 'app.open'),
  (phrase: 'close youtube', action: 'app.close'),
  (phrase: 'open github.com', action: 'open.url'),
  (phrase: 'open www.github.com', action: 'open.url'),

  // --- navigation, weather, location --------------------------------------
  (phrase: 'take me home', action: 'nav.open'),
  (phrase: 'navigate to the office', action: 'nav.open'),
  (phrase: 'take me to the office', action: 'nav.open'),
  (phrase: 'where am i', action: 'location.get'),
  (phrase: 'what is the weather in paris', action: 'weather.get'),
  (phrase: "what's the weather like", action: 'weather.get'),
  (phrase: 'weather in paris', action: 'weather.get'),

  // --- small utilities ----------------------------------------------------
  (phrase: 'roll a dice', action: 'random.dice'),
  (phrase: 'flip a coin', action: 'random.coin'),
  (phrase: 'random 1 to 100', action: 'random.number'),
  (phrase: 'tell me a joke', action: 'tell.joke'),
  (phrase: 'define serendipity', action: 'define.word'),
  (phrase: 'translate hello to French', action: 'translate.text'),
  (phrase: 'convert 5 miles to km', action: 'convert.unit'),
  (phrase: 'convert 100 usd to eur', action: 'convert.unit'),

  // --- files and the serial node ------------------------------------------
  (phrase: 'get report.pdf from my pc', action: 'file.fetch'),
  (phrase: 'blink the ESP32', action: 'led.blink'),

  // --- greetings -----------------------------------------------------------
  (phrase: 'hello', action: 'greet'),
  (phrase: 'hi', action: 'greet'),
  (phrase: 'good morning', action: 'greet'),

  // --- radios, restarts, and finding the phone -----------------------------
  (phrase: 'airplane mode on', action: 'device.airplane'),
  (phrase: 'turn on airplane mode', action: 'device.airplane'),
  (phrase: 'enable airplane mode', action: 'device.airplane'),
  (phrase: 'restart my phone', action: 'device.restart'),
  (phrase: 'reboot', action: 'device.restart'),
  (phrase: 'restart the computer', action: 'device.restart'),
  (phrase: 'find my phone', action: 'device.find'),
  (phrase: 'where is my phone', action: 'device.find'),
  (phrase: 'locate my phone', action: 'device.find'),
  (phrase: 'ring my phone', action: 'device.ring'),
  (phrase: 'make my phone ring', action: 'device.ring'),
  (phrase: 'ring the phone', action: 'device.ring'),

  // --- the clock app's two lists -------------------------------------------
  (phrase: 'show my alarms', action: 'alarm.show'),
  (phrase: 'show alarms', action: 'alarm.show'),
  (phrase: 'list alarms', action: 'alarm.show'),
  (phrase: 'what alarms do i have', action: 'alarm.show'),
  (phrase: 'stop the alarm', action: 'alarm.dismiss'),
  (phrase: 'turn off the alarm', action: 'alarm.dismiss'),
  (phrase: 'dismiss alarm', action: 'alarm.dismiss'),
  (phrase: 'timer status', action: 'timer.status'),
  (phrase: 'how much time is left', action: 'timer.status'),
  (phrase: 'how long is left', action: 'timer.status'),
  (phrase: 'cancel the timer', action: 'timer.cancel'),
  (phrase: 'stop the timer', action: 'timer.cancel'),
  (phrase: 'cancel my timer', action: 'timer.cancel'),

  // --- who the assistant is, and who the user is ---------------------------
  (phrase: 'who are you', action: 'intro'),
  (phrase: 'what are you', action: 'intro'),
  (phrase: 'my name is sam', action: 'profile.set'),
  (phrase: 'call me sam', action: 'profile.set'),
  (phrase: "what's my name", action: 'profile.get'),
  (phrase: 'who am i', action: 'profile.get'),

  // --- calendar, at the shape the parser knows -----------------------------
  (phrase: 'add lunch with mom to my calendar', action: 'calendar.add'),
  (phrase: 'put dentist on my calendar', action: 'calendar.add'),
  (phrase: "what's on my calendar", action: 'calendar.read'),
  (phrase: 'my calendar', action: 'calendar.read'),
  (phrase: "what's my schedule today", action: 'calendar.read'),

  // --- which app is the default -------------------------------------------
  (phrase: 'use spotify for music', action: 'assistant.appDefault'),
  (phrase: 'stop using spotify', action: 'assistant.appDefault'),

  // --- settings, memory, lists, and the clock elsewhere --------------------
  (phrase: 'dark mode on', action: 'display.dark'),
  (phrase: 'turn on dark mode', action: 'display.dark'),
  (phrase: 'enable dark mode', action: 'display.dark'),
  (phrase: 'forget that', action: 'memory.forget'),
  (phrase: 'forget my bike code', action: 'memory.forget'),
  (phrase: 'forget everything', action: 'memory.forget'),
  (phrase: "what's on my shopping list", action: 'note.shopping.get'),
  (phrase: 'show my shopping list', action: 'note.shopping.get'),
  (phrase: 'what time is it in tokyo', action: 'timezone.get'),
  (phrase: 'what time is it in new york', action: 'timezone.get'),
];

/// Should be understood. Not yet. One entry is one bug.
///
/// The reason string is the report: it names the pass that closes it and what
/// is missing, so closing one is a matter of flipping it into [kMustMatch].
const List<Phrase> kKnownGaps = <Phrase>[
  // French, beyond the media verbs that already work.
  (phrase: 'quelle heure est-il', action: 'time.get'),
  (phrase: 'quelle heure il est', action: 'time.get'),
  (phrase: 'mets un minuteur de 5 minutes', action: 'timer.set'),
  (phrase: 'appelle maman', action: 'comm.call'),
  (phrase: 'envoie un texto a maman', action: 'comm.message'),
  (phrase: 'quel temps fait-il a paris', action: 'weather.get'),
  (phrase: 'allume la lampe torche', action: 'device.flashlight'),
  (phrase: 'quel est mon niveau de batterie', action: 'device.battery'),

  // "put on some jazz" is a music verb the play-prefix does not know, and
  // broadening the prefix is not cheap: "put on my shoes" would then open a
  // Deezer search. The distinction is musical, not lexical — structural.
  (phrase: 'put on some jazz', action: 'music.search'),

  // Voice glue: no punctuation, filler the ASR leaves in.
  (phrase: 'hey nexus what time is it', action: 'time.get'),
  (phrase: 'ok so set a timer for 5 minutes please', action: 'timer.set'),

  // Word order a person actually uses.
  (phrase: 'light on', action: 'device.flashlight'),
  (phrase: 'timer 5 minutes', action: 'timer.set'),
  (phrase: 'alarm 7am', action: 'alarm.set'),

  // Filler that ends up in front of a one-word answer.
  (phrase: 'hey there', action: 'greet'),

  // Two calendar shapes the grammar does not have: an imperative without the
  // "to my calendar" tail, and a time of day that is not the item's title.
  // "schedule a meeting tomorrow at 3" is worse than a gap — it reads the
  // calendar instead of writing to it.
  (phrase: 'add lunch tomorrow at noon', action: 'calendar.add'),
  (phrase: 'schedule a meeting tomorrow at 3', action: 'calendar.add'),

  // A currency question with no phrase of its own: `currency.get` is never
  // emitted by the interpreter (conversion resolves as `convert.unit`), and
  // "what is the exchange rate" is answered out of memory instead.
  (phrase: 'usd to eur', action: 'currency.get'),
  (phrase: 'what is the exchange rate', action: 'currency.get'),

  // The verb carries the object in these, and the phrase lists are exact.
  (phrase: 'read my shopping list', action: 'note.shopping.get'),
  (phrase: 'which app should i use', action: 'assistant.appDefault'),
];

/// Must not reach an action. Every one of these is a sentence where guessing
/// would do something real to a real phone.
const List<String> kMustNotMatch = <String>[
  '',
  '   ',
  'call',
  'set',
  'open',
  'note that',
  'remind me to',
  'search for',
  'blink the',
  '🙂🙂🙂',
  'asdkjhaskjdhaksjdh',
  'this is a very long sentence that names no action at all and keeps going '
      'well past any reasonable length a person would type into a composer',
];

/// Sentences that name a command *and* something the parser cannot honour.
///
/// Kept apart from [kMustNotMatch] because the current answer is not "nothing"
/// — it is the first command, with the routing chatter dropped. Calling mom on
/// WhatsApp when the request said "call mom on facetime … via whatsapp" may be
/// the right guess or the wrong one; nothing in the tree decides that today.
/// Skipped rather than asserted, so the disagreement is visible without
/// pinning either behaviour in place.
const List<Phrase> kShouldAskButActs = <Phrase>[
  (
    phrase: 'call mom on facetime on my phone via whatsapp',
    action: 'comm.call',
  ),
  (
    phrase: 'text mom saying hi and also email dad saying hello and call my boss',
    action: 'comm.message',
  ),
];

void main() {
  const CommandInterpreter interpreter = CommandInterpreter();

  group('A — a real phrasing reaches its action', () {
    for (final Phrase p in kMustMatch) {
      test('"${p.phrase}" -> ${p.action}', () {
        final result = interpreter.interpret(p.phrase);
        expect(
          result.outcome,
          InterpretOutcome.matched,
          reason: '"${p.phrase}" was not understood',
        );
        expect(
          result.command!.action,
          p.action,
          reason: '"${p.phrase}" reached ${result.command!.action}',
        );
      });
    }
  });

  group('C — a sentence that names no action reaches none', () {
    for (final String phrase in kMustNotMatch) {
      test('"${phrase.length > 40 ? '${phrase.substring(0, 40)}...' : phrase}" '
          'matches nothing', () {
        final result = interpreter.interpret(phrase);
        expect(
          result.outcome,
          isNot(InterpretOutcome.matched),
          reason: '"$phrase" reached ${result.command?.action}',
        );
      });
    }
  });

  group('D — names a command and unhonourable extras', () {
    for (final Phrase p in kShouldAskButActs) {
      test(
        '"${p.phrase.substring(0, 30)}..." should ask before acting',
        () {
          final result = interpreter.interpret(p.phrase);
          expect(result.outcome, isNot(InterpretOutcome.matched));
        },
        skip: 'known-gap: compound sentences and routing chatter are not '
            'parsed — the first verb wins today',
      );
    }
  });

  group('B — known gaps', () {
    for (final Phrase p in kKnownGaps) {
      test(
        '"${p.phrase}" -> ${p.action}',
        () {
          final result = interpreter.interpret(p.phrase);
          expect(result.outcome, InterpretOutcome.matched);
          expect(result.command!.action, p.action);
        },
        skip: 'known-gap: not understood yet — see the audit report',
      );
    }
  });
}
