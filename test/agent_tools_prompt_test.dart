// The tool prompt names the user's real paired devices, not an example.
// A hardcoded "My PC" taught the 0.5B to answer with prose about a device
// the user doesn't own instead of emitting TOOL:get_file.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_tools.dart';

void main() {
  test('zero paired devices: files plus reminder, no get_file', () {
    final prompt = toolSystemPrompt('You are Nexus.');
    expect(prompt, contains('list_local_files'));
    expect(prompt, contains('set_reminder'));
    expect(prompt, isNot(contains('get_file')));
    expect(prompt, isNot(contains('My PC')));
  });

  test('one paired device: get_file example names it, not My PC', () {
    final prompt = toolSystemPrompt(
      'You are Nexus.',
      pairedDevices: ['Rehearsal PC'],
    );
    expect(prompt, contains('get_file'));
    expect(prompt, contains('"from": "Rehearsal PC"'));
    expect(prompt, isNot(contains('My PC')));
  });

  test('two paired devices: both names are listed', () {
    final prompt = toolSystemPrompt(
      'You are Nexus.',
      pairedDevices: ['Rehearsal PC', "TVcraft01's phone"],
    );
    expect(prompt, contains('Rehearsal PC'));
    expect(prompt, contains("TVcraft01's phone"));
    expect(prompt, isNot(contains('My PC')));
  });

  test('set_reminder is always offered, with its worked example', () {
    const example =
        'For example, the user asks "remind me to take milk at 6pm" — reply exactly:\n'
        'TOOL:set_reminder {"what": "take milk", "when": "18:00"}';
    for (final devices in const [
      <String>[],
      ['Rehearsal PC'],
      ['Rehearsal PC', "TVcraft01's phone"],
    ]) {
      expect(
        toolSystemPrompt('You are Nexus.', pairedDevices: devices),
        contains(example),
      );
    }
  });

  test('the list_local_files worked example is unchanged', () {
    const example =
        'For example, the user asks "what\'s in my Downloads?" — reply exactly:\n'
        'TOOL:list_local_files {"dir": "Downloads"}';
    for (final devices in const [
      <String>[],
      ['Rehearsal PC'],
      ['Rehearsal PC', "TVcraft01's phone"],
    ]) {
      expect(
        toolSystemPrompt('You are Nexus.', pairedDevices: devices),
        contains(example),
      );
    }
  });
}
