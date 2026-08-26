import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/device_actions.dart';

void main() {
  group('DesktopDeviceActionBackend', () {
    final backend = DesktopDeviceActionBackend();

    test('timer accepts a duration and reports it', () async {
      final result = await backend.run(AgentActions.timerSet, {'seconds': 5});
      expect(result.ok, isTrue);
      expect(result.message, contains('Timer set for 5 seconds'));
    });

    test('timer with a missing duration asks for one', () async {
      final result = await backend.run(AgentActions.timerSet, const {});
      expect(result.ok, isFalse);
      expect(result.message, contains('duration'));
    });

    test('alarm with hour/minute reports the time', () async {
      final result =
          await backend.run(AgentActions.alarmSet, {'hour': 7, 'minute': 30});
      expect(result.ok, isTrue);
      expect(result.message, contains('Alarm set for 07:30'));
    });

    test('alarm without a time asks for one', () async {
      final result = await backend.run(AgentActions.alarmSet, const {});
      expect(result.ok, isFalse);
      expect(result.message, contains('time'));
    });

    test('battery either reads a level or answers that none exists', () async {
      final result = await backend.run(AgentActions.batteryGet, const {});
      expect(result.ok, isTrue);
      expect(
        result.message,
        anyOf(startsWith('Battery at'), contains('No battery found')),
      );
    });

    test('unsupported actions answer honestly', () async {
      final result = await backend.run(AgentActions.torchToggle, const {});
      expect(result.ok, isFalse);
      expect(result.message, contains('not available'));
    });

    test('web search reports the query or a browser failure', () async {
      final result =
          await backend.run(AgentActions.webSearch, {'query': 'weather'});
      expect(
        result.message,
        anyOf(contains('Searching for'), contains('browser')),
      );
    });
  });
}
