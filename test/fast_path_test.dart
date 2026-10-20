// The Siri-shaped commands: recognised before the model is asked, and run by
// the phone's own executor instead. These tests pin the line between a command
// and a conversation — the line that decides whether \"call me maybe\" dials
// somebody.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/fast_path.dart';
import 'package:nexus/core/system_actions.dart';

void main() {
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

    test('a mood is not a command', () {
      expect(fastPathAction("it's dark in here"), isNull);
      expect(fastPathAction('what is 144 divided by 12?'), isNull);
      expect(fastPathAction('who are you?'), isNull);
      expect(fastPathAction('   '), isNull);
    });
  });
}
