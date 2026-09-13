import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/device_actions.dart';
import 'package:nexus/core/system_command.dart';

/// Records the commands the backend would launch, so the suite can assert what
/// it does without opening a browser or popping a desktop notification. The
/// suite-wide default (test/flutter_test_config.dart) launches nothing either;
/// this is the backend saying what it *would* have run.
class _Recorder {
  final commands = <String>[];

  /// Make the next launch fail the way a machine with no browser does.
  bool failNext = false;

  Future<ProcessResult> run(String program, List<String> arguments) async {
    commands.add([program, ...arguments].join(' '));
    if (failNext) throw ProcessException('recorder', const []);
    return ProcessResult(0, 0, '', '');
  }
}

void main() {
  group('DesktopDeviceActionBackend', () {
    late _Recorder recorder;
    late DesktopDeviceActionBackend backend;

    setUp(() {
      recorder = _Recorder();
      backend = DesktopDeviceActionBackend(run: recorder.run);
    });

    test('timer accepts a duration and reports it', () async {
      final result = await backend.run(AgentActions.timerSet, {'seconds': 5});
      expect(result.ok, isTrue);
      expect(result.message, contains('Timer set for 5 seconds'));
      // The timer is two programs: the notification now, and the one that
      // fires when the time is up. Both are recorded rather than run.
      expect(recorder.commands, hasLength(2));
      expect(
        recorder.commands.first,
        'notify-send -t 5000 Nexus · Timer Timer set for 5 seconds.',
      );
      expect(
        recorder.commands.last,
        'sh -c sleep 5; notify-send "Nexus · Timer" "Timer finished."',
      );
    });

    test('timer with a missing duration asks for one', () async {
      final result = await backend.run(AgentActions.timerSet, const {});
      expect(result.ok, isFalse);
      expect(result.message, contains('duration'));
      expect(recorder.commands, isEmpty, reason: 'nothing to announce');
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
        expect(recorder.commands, isEmpty);
      },
    );

    test('alarm without a time answers honestly too', () async {
      final result = await backend.run(AgentActions.alarmSet, const {});
      expect(result.ok, isFalse);
      expect(result.message, isNotEmpty);
      expect(recorder.commands, isEmpty);
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
        expect(recorder.commands, isEmpty);
      },
    );

    test('unsupported actions answer honestly, and say where it works', () async {
      // Screenshots are the executor's job on Linux, not the backend's — so
      // the backend must answer honestly, never pretend, and never leave the
      // user with a verdict they cannot act on. "Not available on this device"
      // named neither the thing nor a system that has it. Pinned to Linux
      // because this is the Linux backend's answer, and the message names the
      // system it was produced on.
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        final result = await backend.run(AgentActions.screenshot, const {});
        expect(result.ok, isFalse);
        expect(result.message, contains('Linux'));
        expect(result.message, contains('Nexus does that on'));
        expect(recorder.commands, isEmpty);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('web search reports the query or a browser failure', () async {
      final result = await backend.run(AgentActions.webSearch, {
        'query': 'weather',
      });
      expect(
        result.message,
        anyOf(contains('Searching for'), contains('browser')),
      );
      // With the launched program recorded instead of run, the outcome is
      // deterministic — and the URL is the app's own decision, not a guess.
      expect(result.message, 'Searching for "weather".');
      expect(recorder.commands, [
        'xdg-open https://www.google.com/search?q=weather',
      ]);
    });

    test('a browser that will not open is reported, not swallowed', () async {
      recorder.failNext = true;
      final result = await backend.run(AgentActions.webSearch, {
        'query': 'weather',
      });
      expect(result.ok, isFalse);
      expect(result.message, contains('browser'));
    });

    test('a web search with no query asks for one', () async {
      final result = await backend.run(AgentActions.webSearch, const {});
      expect(result.ok, isFalse);
      expect(result.message, contains('search for'));
      expect(recorder.commands, isEmpty);
    });

    test('an uninjected backend launches through the shared system runner',
        () async {
      // Production behaviour, proven rather than assumed: with no runner
      // passed, the backend reaches the one shared seam — which the product
      // sets to exactly `Process.run` and the test suite replaces.
      final previous = systemCommandRunner;
      final spy = _Recorder();
      systemCommandRunner = spy.run;
      try {
        final production = DesktopDeviceActionBackend();
        final result = await production.run(AgentActions.webSearch, {
          'query': 'weather',
        });
        expect(result.ok, isTrue);
        expect(spy.commands, [
          'xdg-open https://www.google.com/search?q=weather',
        ]);
      } finally {
        systemCommandRunner = previous;
      }
    });
  });
}
