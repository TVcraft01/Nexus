// The phrase a user types, straight to the call the phone runs.
//
// This is the regression test for the phone pass's worst finding: "set
// brightness to 60" reached the model, came back as the sentence "Brightness
// set to 60%." and executed nothing. The four settings actions have a closed
// vocabulary, so the shell must not need a model to recognise them — and must
// not act on the phrasings it cannot fully read.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/system_actions.dart';

void main() {
  /// The call a phrase produces, as `action state/level`, or 'prose' when it is
  /// the model's to answer.
  String read(String text) {
    final SystemActionCall? call = actionFromPhrase(text);
    if (call == null) return 'prose';
    final String args = call.args.entries
        .map((MapEntry<String, Object?> e) => '${e.key}=${e.value}')
        .join(',');
    return '${call.action} $args'.trim();
  }

  group('the settings a phone can be asked for', () {
    test('volume, in the words a person uses', () {
      expect(read('set volume to 30'), 'set_volume level=30');
      expect(read('set the volume to 30'), 'set_volume level=30');
      expect(read('volume 100'), 'set_volume level=100');
      expect(read('volume 0'), 'set_volume level=0');
    });

    test('brightness, with the verb the phone was actually asked with', () {
      expect(read('set brightness to 60'), 'set_brightness level=60');
      expect(read('set the brightness to 20'), 'set_brightness level=20');
      expect(read('brightness 100'), 'set_brightness level=100');
      expect(read('brightness 60%'), 'set_brightness level=60');
    });

    test('the two radios, both ways', () {
      expect(read('turn on wifi'), 'set_wifi state=on');
      expect(read('wifi off'), 'set_wifi state=off');
      expect(read('turn on bluetooth'), 'set_bluetooth state=on');
      expect(read('turn off bluetooth'), 'set_bluetooth state=off');
      expect(read('enable bluetooth'), 'set_bluetooth state=on');
    });

    test('the torch, which is the one that already worked', () {
      expect(read('turn on the flashlight'), 'set_flashlight state=on');
      expect(read('turn the torch off'), 'set_flashlight state=off');
    });
  });

  group('what is deliberately left to the model', () {
    test('a toggle has no state to send', () {
      // Guessing `on` would turn a request to turn the light off into one to
      // turn it on. The model decides, or nothing happens.
      expect(read('flashlight'), 'prose');
      expect(read('toggle bluetooth'), 'prose');
      expect(read('wifi'), 'prose');
    });

    test('a relative step is not a level', () {
      expect(read('brighter'), 'prose');
      expect(read('dimmer'), 'prose');
      expect(read('volume up'), 'prose');
      expect(read('louder'), 'prose');
    });

    test('a level out of range is refused, not clamped', () {
      expect(read('brightness 0'), 'prose');
      expect(read('brightness 300'), 'prose');
      expect(read('volume 300'), 'prose');
    });

    test('anything that is a question stays a question', () {
      expect(read('what is my battery at'), 'prose');
      expect(read('why is it so dark in here'), 'prose');
      expect(read(''), 'prose');
      expect(read('hello'), 'prose');
    });
  });
}
