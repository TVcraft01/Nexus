// The Siri-shaped commands: recognised before the model is asked, and run by
// the phone's own executor instead. These tests pin the line between a command
// and a conversation — the line that decides whether \"call me maybe\" dials
// somebody.
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/fast_path.dart';
import 'package:nexus/core/system_actions.dart';

void main() {
  // These are the sentences a user says to their *phone*. The Core-15 half of
  // the fast path is deliberately Android-only (the desktop shell leaves those
  // phrases to the model); the one test below that cares about the desktop
  // overrides this back.
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() => debugDefaultTargetPlatformOverride = null);
  group('calling', () {
    test('a contact name is the target', () {
      final SystemActionCall? call = fastPathAction('Call mom');

      expect(call, isNotNull);
      expect(call!.action, 'call_number');
      expect(call.args['number'], 'mom');
    });

    test('a number is dialled unchanged', () {
      final SystemActionCall? call = fastPathAction('call +1 (555) 123-4567.');

      expect(call!.action, 'call_number');
      expect(call.args['number'], '+1 (555) 123-4567');
    });

    test('"dial" is the same verb', () {
      final SystemActionCall? call = fastPathAction('dial the garage');

      expect(call!.action, 'call_number');
      expect(call.args['number'], 'garage');
    });

    test('an idiom is a conversation, not a call', () {
      for (final String phrase in <String>[
        'call me maybe',
        'call it a day',
        'call this off',
        'call back later',
        'call',
      ]) {
        expect(fastPathAction(phrase), isNull, reason: phrase);
      }
    });

    test('a device marker stays out of the contact name', () {
      final SystemActionCall? call = fastPathAction('call mom on my phone');

      expect(call!.action, 'call_number');
      expect(call.args['number'], 'mom');
    });

    test('the confirmation keeps the spelling of the name', () {
      // The interpreter lower-cases to match; what the phone echoes back in
      // "No contact named …" or "Opened the dialer for …" is the user's own
      // name, so it must survive as they typed it.
      expect(fastPathAction('call TVcraft01')!.args['number'], 'TVcraft01');
      expect(
        fastPathAction('call Mary-Jane on my phone')!.args['number'],
        'Mary-Jane',
      );
    });

    test('a video call stays with the model', () {
      expect(fastPathAction('video call mom'), isNull);
      expect(fastPathAction('call mom on facetime'), isNull);
    });
  });

  group('the phone’s other hands', () {
    test('the flashlight is switched, not guessed at', () {
      final SystemActionCall? on = fastPathAction('turn on the flashlight');
      final SystemActionCall? off = fastPathAction('turn the flashlight off');

      expect(on!.action, 'set_flashlight');
      expect(on.args['state'], 'on');
      expect(off!.action, 'set_flashlight');
      expect(off.args['state'], 'off');
    });

    test('a timer becomes the seconds the clock app needs', () {
      final SystemActionCall? timer = fastPathAction(
        'Set a timer for 5 minutes',
      );

      expect(timer!.action, 'set_timer');
      expect(timer.args['seconds'], 300);
    });

    test('music is played and paused, and only when it was asked for', () {
      expect(fastPathAction('Play some music')!.action, 'play_music');
      // The other half of the pair: "pause music" used to reach the model,
      // which answered by opening the player over the music that was playing.
      for (final String phrase in <String>[
        'pause music',
        'Pause the music',
        'stop music',
      ]) {
        expect(fastPathAction(phrase)!.action, 'pause_music', reason: phrase);
      }
      // A bare "pause" may be about a video or a preview, so it stays a
      // conversation rather than becoming a media key.
      expect(fastPathAction('pause'), isNull);
      expect(fastPathAction('play that again'), isNull);
    });

    test('the battery is read by the phone, not asked of the model', () {
      expect(fastPathAction('battery')!.action, 'get_battery_level');
      expect(
        fastPathAction('how much battery is left')!.action,
        'get_battery_level',
      );
    });

    test('the weather is answered honestly, and only for weather', () {
      expect(fastPathReply("what's the weather?"), kNoWeatherText);
      expect(fastPathReply('will it rain tomorrow'), kNoWeatherText);
      expect(kNoWeatherText, contains('internet access'));
      // A remark is not a request: "it's raining" is a conversation.
      expect(fastPathReply("it's raining"), isNull);
      expect(fastPathReply('what is a mesh?'), isNull);
    });

    test('the alarm is set by the clock, at the time that was spoken', () {
      final SystemActionCall? alarm = fastPathAction('set an alarm for 7am');

      expect(alarm!.action, 'set_alarm');
      expect(alarm.args, <String, Object?>{'hour': 7, 'minute': 0});
      expect(fastPathAction('wake me up at 6:45')!.args, <String, Object?>{
        'hour': 6,
        'minute': 45,
      });
      // An alarm with no time is a question the model may ask; it is not a
      // guessed 07:30.
      expect(fastPathAction('set an alarm'), isNull);
    });

    test('the clock’s own lists open without a model', () {
      expect(fastPathAction('show my alarms')!.action, 'show_alarms');
      expect(fastPathAction('show my alarms')!.args['what'], 'alarms');
      expect(fastPathAction('open my timers')!.args['what'], 'timers');
      expect(fastPathAction('cancel the timer')!.action, 'cancel_timers');
      expect(fastPathAction('stop my alarm')!.action, 'cancel_alarms');
    });
  });

  group('the rest of the Core 15', () {
    test('a text keeps the recipient and the draft', () {
      final SystemActionCall sms = fastPathAction('text mom saying on my way')!;

      expect(sms.action, 'send_sms');
      expect(sms.args['contact'], 'mom');
      expect(sms.args['body'], 'on my way');
      // The device marker names where the text goes, not who it goes to.
      expect(fastPathAction('text dad on my phone')!.args['contact'], 'dad');
    });

    test('an email is the same shape through the mail app', () {
      final SystemActionCall mail = fastPathAction('email John')!;

      expect(mail.action, 'send_email');
      expect(mail.args['contact'], 'John');
      expect(
        fastPathAction('send an email to mom saying hi')!.action,
        'send_email',
      );
    });

    test('skip and previous reach the media key', () {
      expect(fastPathAction('skip this song')!.action, 'next_song');
      expect(fastPathAction('next track')!.action, 'next_song');
      expect(fastPathAction('play the previous song')!.action, 'previous_song');
    });

    test('a place is a map search, not a conversation about one', () {
      final SystemActionCall nav = fastPathAction('navigate to Paris')!;

      expect(nav.action, 'navigate_to');
      expect(nav.args['destination'], 'Paris');
      expect(
        fastPathAction('take me to the office')!.args['destination'],
        'the office',
      );
    });

    test('an app the interpreter knows is launched by name', () {
      final SystemActionCall app = fastPathAction('open Spotify')!;

      expect(app.action, 'open_app');
      expect(app.args['app_name'], 'Spotify');
      // A name nobody knows is not a fast-path open; the model may still help.
      expect(fastPathAction('open qqq'), isNull);
    });

    test('a screenshot and a joke are instant', () {
      expect(fastPathAction('take a screenshot')!.action, 'screenshot');
      expect(fastPathAction('tell me a joke')!.action, 'tell_joke');
    });

    test('only the sentences that name the medium are texts or emails', () {
      // The interpreter's rule is broad on purpose — `message <someone>` is
      // how people ask for a draft. The fast path opens the composer, so it
      // takes only the unambiguous half: a word that names SMS or mail.
      expect(fastPathAction('message me later'), isNull);
      expect(fastPathAction('message number 3'), isNull);
      expect(fastPathAction('mail the package'), isNull);
      expect(fastPathAction('text mom')!.action, 'send_sms');
      expect(fastPathAction('send a text to dad')!.action, 'send_sms');
      expect(fastPathAction('send an e mail to mom')!.action, 'send_email');
    });

    test('on a PC the phone’s intents are left to the model', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;

      // The desktop backend has no `open_app` or `screenshot` behind it, and
      // answering "I can't open apps by name on Linux — Nexus does that on
      // Windows, Linux and your phone" would be both a regression and a
      // contradiction. The shell keeps its old behaviour there.
      expect(fastPathAction('open Spotify'), isNull);
      expect(fastPathAction('take a screenshot'), isNull);
      expect(fastPathAction('text mom'), isNull);
      // …while the answers that need no phone still arrive.
      expect(fastPathAction('tell me a joke')!.action, 'tell_joke');
      expect(fastPathReply("what's the weather?"), kNoWeatherText);
    });

    test('a mood is not a command', () {
      expect(fastPathAction("it's dark in here"), isNull);
      expect(fastPathAction('what is 144 divided by 12?'), isNull);
      expect(fastPathAction('who are you?'), isNull);
      expect(fastPathAction('   '), isNull);
    });
  });
}
