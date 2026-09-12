// The class rule for "Nexus can't do that here".
//
// A capability gap used to be reported as a bare verdict — "That action is not
// available on this device." — which named neither what Nexus could not do nor
// a system that can do it, so it was a dead end for the user rather than an
// answer. These tests pin the rule: every gap answer names the system the user
// is on *and* the systems that have the capability, and the banned phrasings
// cannot come back.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/device_actions.dart';

/// The verdicts with nothing behind them. Each one tells the user that
/// something is impossible without ever saying what, why, or where it is
/// possible — the opposite of an explanation.
const _bareVerdicts = [
  'not available on this device',
  'not available on this platform',
  'not supported on this platform',
  'not available here',
  'is unavailable',
];

/// Every action that can reach a platform gap, i.e. that Nexus implements on
/// some systems and not others.
const _gappedActions = [
  AgentActions.appOpen,
  AgentActions.appClose,
  AgentActions.screenshot,
  AgentActions.batteryGet,
  AgentActions.brightnessSet,
  AgentActions.flashlightToggle,
  AgentActions.wifiToggle,
  AgentActions.bluetoothToggle,
  AgentActions.lockScreen,
  AgentActions.mediaPlay,
  AgentActions.alarmSet,
  AgentActions.volumeSet,
  AgentActions.calendarRead,
];

void main() {
  /// Runs [body] as if Nexus were on [platform].
  T on<T>(TargetPlatform platform, T Function() body) {
    debugDefaultTargetPlatformOverride = platform;
    try {
      return body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  group('a platform gap is an explanation, never a verdict', () {
    for (final action in _gappedActions) {
      test('$action says what and where, on every system', () {
        for (final platform in TargetPlatform.values) {
          final message = on(platform, () => notOnThisSystem(action));
          final where = platformName();
          expect(
            message,
            contains(where),
            reason: 'the user is not told which system they are on',
          );
          expect(
            message,
            contains('Nexus does that on'),
            reason: 'the user is not told where the action does work',
          );
          for (final bare in _bareVerdicts) {
            expect(
              message.toLowerCase(),
              isNot(contains(bare)),
              reason: 'a bare verdict is not an answer',
            );
          }
        }
      });
    }

    test('the system the user is on is named in their terms', () {
      expect(on(TargetPlatform.android, platformName), 'your phone');
      expect(on(TargetPlatform.linux, platformName), 'Linux');
      expect(on(TargetPlatform.windows, platformName), 'Windows');
      expect(on(TargetPlatform.macOS, platformName), 'macOS');
      // Never the developer word: the user is on a system, not a platform.
      for (final platform in TargetPlatform.values) {
        expect(on(platform, platformName), isNot(contains('platform')));
      }
    });

    test('an action with no table entry invents nothing', () {
      // The fallback has to be honest too: no entry must not mean no answer,
      // and it must not mean a guess about who can do it either.
      final message = on(
        TargetPlatform.linux,
        () => notOnThisSystem('made.up'),
      );
      expect(message, contains('Linux'));
      expect(message, isNot(contains('Nexus does that on')));
      for (final bare in _bareVerdicts) {
        expect(message.toLowerCase(), isNot(contains(bare)));
      }
    });

    test('the shared sentence builder is the only shape', () {
      expect(
        on(
          TargetPlatform.windows,
          () => gapAnswer('open your system settings', 'Windows and Linux'),
        ),
        "I can't open your system settings on Windows — "
        'Nexus does that on Windows and Linux.',
      );
    });
  });

  group('the backends answer with that explanation too', () {
    /// One action per system that the backend genuinely cannot run — a gap the
    /// user can actually hit, not a hypothetical one.
    const gaps = <TargetPlatform, List<String>>{
      // Windows and macOS have no native device channel at all.
      TargetPlatform.windows: [
        AgentActions.calendarRead,
        AgentActions.screenshot,
        AgentActions.flashlightToggle,
      ],
      TargetPlatform.macOS: [AgentActions.calendarRead, AgentActions.appClose],
      // Linux gets a desktop backend that handles timers and search; the rest
      // is a gap it has to name.
      TargetPlatform.linux: [
        AgentActions.calendarRead,
        AgentActions.screenshot,
      ],
      TargetPlatform.fuchsia: [AgentActions.calendarRead],
    };

    gaps.forEach((platform, actions) {
      for (final action in actions) {
        test('${platform.name} / $action is explained, not dismissed', () async {
          final message =
              (await on(platform, deviceActionBackend).run(
                action,
                const {},
              )).message;
          expect(message, contains(platformName()));
          expect(message, contains('Nexus does that on'));
          for (final bare in _bareVerdicts) {
            expect(message.toLowerCase(), isNot(contains(bare)));
          }
        });
      }
    });
  });

  group('the rule is enforced in the source, not just at these sites', () {
    test('no bare platform verdict is left anywhere in lib/', () {
      // The class guard: a new action that answers "not available on this
      // device" would pass any per-site test and still be the same dead end,
      // so the banned phrasings are checked across the whole app.
      final offenders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        for (final line in entity.readAsLinesSync()) {
          final code = line.trimLeft();
          // Comments are how the rule is *written down*; only what the app can
          // actually say to a user is in scope.
          if (code.startsWith('//') || code.startsWith('*')) continue;
          final lower = code.toLowerCase();
          for (final bare in _bareVerdicts) {
            if (lower.contains(bare)) {
              offenders.add('${entity.path}: "$bare" in $code');
            }
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'every "Nexus cannot do this here" answer must name what it could '
            'not do and where it works — use notOnThisSystem/gapAnswer',
      );
    });
  });
}
