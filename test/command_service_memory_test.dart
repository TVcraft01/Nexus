import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/command_service.dart';

void main() {
  const devices = [
    AgentDeviceSnapshot(
      id: 'esp32',
      name: 'Desk ESP32',
      online: true,
      capabilities: [DeviceCapability(AgentActions.ledBlink)],
    ),
    AgentDeviceSnapshot(id: 'phone', name: 'My Phone', online: true),
  ];

  CommandService makeService({AgentMemory? memory, void Function()? onChanged}) =>
      CommandService(
        devices: () => devices,
        memory: memory ?? const AgentMemory(),
        onMemoryChanged: onChanged,
      );

  test('"play my playlist" asks, remembers the answer, then uses it', () {
    var saved = 0;
    final service = makeService(onChanged: () => saved++);

    // First time: needs the playlist name.
    final first = service.execute('play my playlist');
    expect(first.status, AgentResultStatus.needsInfo);
    final ask = first.dispatch! as AgentClarification;
    expect(ask.key, 'arg:media.play.playlist');
    expect(ask.question, contains('playlist'));

    // Answer it.
    final answered = service.execute('Chill Mix', answerTo: ask.key);
    expect(answered.status, AgentResultStatus.unavailable); // no player wired yet
    expect(answered.message, contains('Chill Mix'));
    expect(saved, 1); // the default was persisted

    // Second time: no question — the default is remembered.
    final second = service.execute('play my playlist');
    expect(second.status, AgentResultStatus.unavailable);
    expect(second.message, contains('Chill Mix'));
    expect(second.dispatch, isNull); // no clarification asked again
  });

  test('an explicit playlist name bypasses the question', () {
    final service = makeService();
    final result = service.execute('play chill vibes');
    expect(result.status, AgentResultStatus.unavailable);
    expect(result.message, contains('chill vibes'));
    expect(result.dispatch, isNull);
  });

  test('a taught phrase is understood next time', () {
    final service = makeService();

    // "bring me home" is unknown → teaching prompt.
    final first = service.execute('bring me home');
    expect(first.status, AgentResultStatus.needsInfo);
    final ask = first.dispatch! as AgentClarification;
    expect(ask.key, startsWith('teach:bring me home'));

    // Teach it: it means "show my devices".
    final taught = service.execute('show my devices', answerTo: ask.key);
    expect(taught.status, AgentResultStatus.succeeded);
    expect((taught.dispatch! as AgentDeviceList).devices, devices);

    // Next time, "bring me home" just works.
    final second = service.execute('bring me home');
    expect(second.status, AgentResultStatus.succeeded);
    expect((second.dispatch! as AgentDeviceList).devices, devices);
  });

  test('teaching only accepts recognized commands', () {
    final service = makeService();
    final first = service.execute('teleport me to mars');
    final ask = first.dispatch! as AgentClarification;

    final bad = service.execute('still gibberish', answerTo: ask.key);
    expect(bad.status, AgentResultStatus.needsInfo); // still asking

    final good = service.execute('blink the esp32', answerTo: ask.key);
    expect(good.status, AgentResultStatus.required); // target exists → approval
  });

  test('memory is seeded from a previous session', () {
    final service = makeService(
      memory: const AgentMemory(
        learned: {'bring me home': 'show my devices'},
        defaults: {'media.play.playlist': 'Chill Mix'},
      ),
    );
    expect(service.execute('bring me home').status, AgentResultStatus.succeeded);
    final result = service.execute('play my playlist');
    expect(result.message, contains('Chill Mix'));
    expect(result.dispatch, isNull);
  });
}
