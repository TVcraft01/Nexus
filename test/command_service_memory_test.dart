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

  CommandService makeService({
    AgentMemory? memory,
    void Function()? onChanged,
  }) => CommandService(
    devices: () => devices,
    memory: memory ?? const AgentMemory(),
    onMemoryChanged: onChanged,
  );

  test('"set a timer" asks, remembers the answer, then uses it', () {
    var saved = 0;
    final service = makeService(onChanged: () => saved++);

    // First time: the duration is missing.
    final first = service.execute('set a timer');
    expect(first.status, AgentResultStatus.needsInfo);
    final ask = first.dispatch! as AgentClarification;
    expect(ask.key, 'arg:timer.set.seconds');
    expect(ask.question, contains('long'));

    // Answer it in plain words — the ask flow parses it to real seconds.
    final answered = service.execute('5 minutes', answerTo: ask.key);
    expect(answered.status, AgentResultStatus.succeeded);
    final msg = answered.dispatch! as AgentMessage;
    expect(msg.text, contains('5m 0s'));
    expect(msg.arguments?['seconds'], 300);
    expect(saved, 1); // the default was persisted

    // Second time: no question — the default is remembered.
    final second = service.execute('set a timer');
    expect(second.status, AgentResultStatus.succeeded);
    expect((second.dispatch! as AgentMessage).arguments?['seconds'], 300);
    expect(second.dispatch, isA<AgentMessage>()); // no clarification re-asked
  });

  test('an explicit duration bypasses the question', () {
    final service = makeService();
    final result = service.execute('set a timer for 5 minutes');
    expect(result.status, AgentResultStatus.succeeded);
    expect((result.dispatch! as AgentMessage).arguments?['seconds'], 300);
  });

  test('an unparseable answer keeps asking instead of wedging the command', () {
    final service = makeService();
    final ask = service.execute('set a timer').dispatch! as AgentClarification;

    // "two minutes" is not a duration Nexus can parse — it re-asks rather
    // than remembering a default that can never run.
    final bad = service.execute('two minutes', answerTo: ask.key);
    expect(bad.status, AgentResultStatus.needsInfo);
    expect((bad.dispatch! as AgentClarification).key, ask.key);

    // A usable answer then works, and is remembered.
    final good = service.execute('5 minutes', answerTo: ask.key);
    expect(good.status, AgentResultStatus.succeeded);
    expect((good.dispatch! as AgentMessage).arguments?['seconds'], 300);
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
        defaults: {'timer.set.seconds': 300},
      ),
    );
    expect(
      service.execute('bring me home').status,
      AgentResultStatus.succeeded,
    );
    final result = service.execute('set a timer');
    expect(result.status, AgentResultStatus.succeeded);
    expect((result.dispatch! as AgentMessage).arguments?['seconds'], 300);
  });
}
