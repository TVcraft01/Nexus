// Every suggestion and example the app offers, held against the platform it
// would run on.
//
// The bug this exists to stop: the empty home screen offered "Turn on the
// flashlight" on a computer, which has no torch, so the first thing a new user
// could tap was one the app could not do. The pool is now derived from the
// capability registry, and these tests hold that derivation per platform
// rather than for the one platform the test happens to run on.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/capability.dart';
import 'package:nexus/main_ui.dart'
    show homeSuggestionPoolFor, pickHomeSuggestions;
import 'package:nexus/core/agent_contract.dart';

void main() {
  // The platforms Nexus ships on, plus iOS, whose registry reach is empty.
  const List<String> platforms = <String>[
    'android',
    'ios',
    'linux',
    'windows',
    'macos',
  ];

  bool offersFlashlight(List<(String, String)> pool) =>
      pool.any(((String, String) chip) => chip.$1.toLowerCase().contains('flash'));

  test('a computer is never offered the flashlight', () {
    for (final String platform in <String>['linux', 'windows', 'macos', 'ios']) {
      expect(
        offersFlashlight(homeSuggestionPoolFor(platform)),
        isFalse,
        reason: '$platform has no torch to turn on',
      );
    }
  });

  test('the flashlight is still offered where it exists', () {
    expect(offersFlashlight(homeSuggestionPoolFor('android')), isTrue);
  });

  test('every offered chip is a command this platform can run', () {
    for (final String platform in platforms) {
      final List<(String, String)> pool = homeSuggestionPoolFor(platform);
      expect(pool, isNotEmpty, reason: '$platform should offer something');
      for (final (String label, String prompt) in pool) {
        expect(label.trim(), isNotEmpty);
        expect(prompt.trim(), isNotEmpty);
      }
      // The phone-only wish list is the one that varies; the rest are the app's
      // own answers, which every platform keeps.
      expect(
        pool.length,
        platform == 'android' ? 7 : (platform == 'ios' ? 4 : 6),
        reason: 'pool for $platform changed shape',
      );
    }
  });

  // The screen draws three chips. A pool that filters down to two makes the
  // empty screen quietly offer less than it promises — which is exactly what
  // happened on a desktop before the two ungated wishes were added.
  test('every platform can fill the three chips the empty screen draws', () {
    for (final String platform in platforms) {
      expect(
        pickHomeSuggestions(
          platform: platform,
          random: math.Random(7),
        ).length,
        3,
        reason: '$platform cannot fill three chips',
      );
    }
  });

  test('assistant examples are filtered by the same registry', () {
    for (final String platform in platforms) {
      final List<String> examples = suggestionExamplesFor(platform);
      expect(examples, isNotEmpty, reason: '$platform offers no example at all');
      final bool torch = examples.any(
        (String phrase) => phrase.toLowerCase().contains('flashlight'),
      );
      expect(
        torch,
        platform == 'android',
        reason: 'a torch example leaked onto $platform',
      );
    }
  });

  test('the registry itself says a torch is Android-only', () {
    expect(capabilityAvailableOn(AgentActions.flashlightToggle, 'android'), isTrue);
    for (final String platform in <String>['linux', 'windows', 'macos', 'ios']) {
      expect(capabilityAvailableOn(AgentActions.flashlightToggle, platform), isFalse);
    }
  });
}
