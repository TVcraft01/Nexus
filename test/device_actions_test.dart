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

    test(
      'alarm with hour/minute is never silently dropped at the backend layer',
      () async {
        // Desktop alarms run in the view (it opens the system clock app); the
        // action backend itself must answer honestly instead of pretending it
        // set one.
        final result = await backend.run(AgentActions.alarmSet, {
          'hour': 7,
          'minute': 30,
        });
        expect(result.ok, isFalse);
        expect(result.message, isNotEmpty);
      },
    );

    test('alarm without a time answers honestly too', () async {
      final result = await backend.run(AgentActions.alarmSet, const {});
      expect(result.ok, isFalse);
      expect(result.message, isNotEmpty);
    });

    test(
      'battery is answered honestly when the backend cannot read it',
      () async {
        // Battery reads happen in the platform-specific view executors
        // (e.g. /sys/class/power_supply on Linux); the backend must never
        // claim a level it did not measure.
        final result = await backend.run(AgentActions.batteryGet, const {});
        expect(result.ok, isFalse);
        expect(result.message, isNotEmpty);
      },
    );

    test('unsupported actions answer honestly', () async {
      // airplaneModeSet is not routed by the device backend — it must
      // answer honestly, never pretend.
      final result = await backend.run(AgentActions.airplaneModeSet, const {});
      expect(result.ok, isFalse);
      expect(result.message, contains('not available'));
    });

    test('web search reports the query or a browser failure', () async {
      final result = await backend.run(AgentActions.webSearch, {
        'query': 'weather',
      });
      expect(
        result.message,
        anyOf(contains('Searching for'), contains('browser')),
      );
    });
  });
}
