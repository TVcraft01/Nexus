// The registry's own guards. These are the tests that keep the five partial
// owners from growing back: one entry per action, every example proven to
// parse to the action it is filed under, and the platform sets frozen to the
// exact lists this refactor replaced.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/capability.dart';
import 'package:nexus/core/command_interpreter.dart';

/// Every action the contract declares. Written out deliberately: adding a
/// constant to [AgentActions] without giving it a capability must fail here,
/// and this list is compile-checked so a renamed constant cannot drift.
const _allActionIds = <String>[
  AgentActions.deviceList,
  AgentActions.ledBlink,
  AgentActions.greet,
  AgentActions.timeGet,
  AgentActions.mathCalc,
  AgentActions.helpGet,
  AgentActions.clipboardWrite,
  AgentActions.webSearch,
  AgentActions.noteCreate,
  AgentActions.timerSet,
  AgentActions.openUrl,
  AgentActions.systemInfo,
  AgentActions.volumeSet,
  AgentActions.appOpen,
  AgentActions.appClose,
  AgentActions.screenshot,
  AgentActions.batteryGet,
  AgentActions.brightnessSet,
  AgentActions.flashlightToggle,
  AgentActions.airplaneModeSet,
  AgentActions.wifiToggle,
  AgentActions.bluetoothToggle,
  AgentActions.lockScreen,
  AgentActions.deviceRestart,
  AgentActions.callPlace,
  AgentActions.messageSend,
  AgentActions.emailSend,
  AgentActions.mediaPlay,
  AgentActions.mediaPause,
  AgentActions.mediaNext,
  AgentActions.mediaPrev,
  AgentActions.mediaShuffle,
  AgentActions.mediaRepeat,
  AgentActions.alarmSet,
  AgentActions.alarmDismiss,
  AgentActions.timerStatus,
  AgentActions.timerCancel,
  AgentActions.reminderSet,
  AgentActions.weatherGet,
  AgentActions.navOpen,
  AgentActions.locationGet,
  AgentActions.intro,
  AgentActions.musicSearch,
  AgentActions.currencyGet,
  AgentActions.timezoneGet,
  AgentActions.calendarAdd,
  AgentActions.calendarRead,
  AgentActions.appDefault,
  AgentActions.profileSet,
  AgentActions.profileGet,
  AgentActions.shoppingListAdd,
  AgentActions.shoppingListGet,
  AgentActions.darkModeSet,
  AgentActions.defineWord,
  AgentActions.translateText,
  AgentActions.unitConvert,
  AgentActions.randomDice,
  AgentActions.randomCoin,
  AgentActions.randomNumber,
  AgentActions.tellJoke,
  AgentActions.memoryRemember,
  AgentActions.memoryRecall,
  AgentActions.memoryForget,
  AgentActions.memoryQuestion,
  AgentActions.findDevice,
  AgentActions.ringDevice,
];

/// The exact capability set this device used to hand-write for a phone.
const _phoneActions = <String>{
  AgentActions.webSearch,
  AgentActions.noteCreate,
  AgentActions.timerSet,
  AgentActions.openUrl,
  AgentActions.systemInfo,
  AgentActions.volumeSet,
  AgentActions.ledBlink,
  AgentActions.appOpen,
  AgentActions.appClose,
  AgentActions.screenshot,
  AgentActions.batteryGet,
  AgentActions.brightnessSet,
  AgentActions.flashlightToggle,
  AgentActions.wifiToggle,
  AgentActions.bluetoothToggle,
  AgentActions.lockScreen,
  AgentActions.callPlace,
  AgentActions.messageSend,
  AgentActions.emailSend,
  AgentActions.mediaPlay,
  AgentActions.mediaPause,
  AgentActions.mediaNext,
  AgentActions.mediaPrev,
  AgentActions.mediaShuffle,
  AgentActions.mediaRepeat,
  AgentActions.alarmSet,
  AgentActions.alarmDismiss,
  AgentActions.timerStatus,
  AgentActions.timerCancel,
  AgentActions.reminderSet,
  AgentActions.weatherGet,
  AgentActions.navOpen,
  AgentActions.calendarAdd,
  AgentActions.calendarRead,
  AgentActions.darkModeSet,
};

/// The exact capability set this device used to hand-write for a desktop.
const _desktopActions = <String>{
  AgentActions.webSearch,
  AgentActions.noteCreate,
  AgentActions.timerSet,
  AgentActions.timerStatus,
  AgentActions.timerCancel,
  AgentActions.openUrl,
  AgentActions.systemInfo,
  AgentActions.volumeSet,
  AgentActions.ledBlink,
  AgentActions.appOpen,
  AgentActions.screenshot,
  AgentActions.batteryGet,
  AgentActions.weatherGet,
  AgentActions.navOpen,
  AgentActions.darkModeSet,
  AgentActions.mediaPlay,
  AgentActions.mediaPause,
  AgentActions.mediaNext,
  AgentActions.mediaPrev,
  AgentActions.emailSend,
};

void main() {
  group('coverage', () {
    test('every declared action has exactly one capability', () {
      final registryIds = kCapabilities.map((c) => c.id).toList();
      expect(
        registryIds.toSet().length,
        registryIds.length,
        reason: 'a duplicate id is two owners for one action',
      );
      for (final id in _allActionIds) {
        expect(
          capabilityFor(id),
          isNotNull,
          reason: '$id has no capability — declare it in kCapabilities',
        );
      }
    });

    test('the registry declares no action the contract forgot', () {
      for (final capability in kCapabilities) {
        expect(
          _allActionIds,
          contains(capability.id),
          reason: '${capability.id} is not an AgentActions id',
        );
      }
    });

    test('every capability is described in user terms', () {
      for (final capability in kCapabilities) {
        expect(capability.label, isNotEmpty, reason: capability.id);
      }
    });
  });

  group('examples really work', () {
    const interpreter = CommandInterpreter();

    test('every example parses back to the action it is filed under', () {
      for (final capability in kCapabilities) {
        final example = capability.example;
        if (example == null) continue; // not verified yet — no claim made
        final result = interpreter.interpret(example);
        expect(
          result.outcome,
          InterpretOutcome.matched,
          reason: '"$example" should parse (${capability.id})',
        );
        expect(
          result.command!.action,
          capability.id,
          reason: '"$example" parsed as the wrong action',
        );
      }
    });

    test('every fallback suggestion names a real action', () {
      // A chip is allowed to be answered locally (the time, help, memory) —
      // it does *not* have to reach a device backend. What it must never do
      // is name an action nothing declares; the test below proves the phrase
      // actually runs it.
      for (final id in kSuggestionIds) {
        expect(capabilityFor(id), isNotNull, reason: '$id is not a capability');
      }
      expect(suggestionExamples(), isNotEmpty);
    });

    test('a tapped suggestion really runs the action it promises', () {
      // Chips submit their phrase verbatim, so every suggested phrase has to
      // parse to the capability it was drawn from — no decorative buttons.
      for (final id in kSuggestionIds) {
        final capability = capabilityFor(id)!;
        final phrase = capability.suggestExample ?? capability.example;
        expect(phrase, isNotNull, reason: '$id is suggested with no phrase');
        final result = interpreter.interpret(phrase!);
        expect(result.outcome, InterpretOutcome.matched, reason: phrase);
        expect(
          result.command!.action,
          id,
          reason: 'the chip "$phrase" does not do what it says',
        );
      }
    });

    test('the suggested phrases are the ones the assistant always shipped', () {
      expect(suggestionExamples(), const [
        'what can you do',
        'what time is it',
        'what do you know about me',
        'what is the weather in paris',
        'take me home',
        'play my playlist',
        'open youtube',
        'call mom',
        'email mom',
        'flashlight on',
      ]);
    });

    test('every everyday skill has a phrase that parses', () {
      final catalog = skillCatalog();
      expect(catalog, isNotEmpty);
      for (final entry in catalog.entries) {
        final result = interpreter.interpret(entry.value.example);
        expect(
          result.outcome,
          InterpretOutcome.matched,
          reason: entry.value.example,
        );
        expect(result.command!.action, entry.key, reason: entry.value.example);
      }
    });
  });

  group('the help answer is built from the registry', () {
    const interpreter = CommandInterpreter();

    test('every offered phrase resolves to the capability that offers it', () {
      // The rule that makes the answer safe to derive: the registry may only
      // offer a phrase that means the thing it is filed under. A phrase the
      // interpreter reads as something else — or as nothing — cannot be
      // advertised, because the answer would be lying about it.
      for (final capability in kCapabilities) {
        for (final phrase in phrasesOf(capability)) {
          final result = interpreter.interpret(phrase);
          expect(
            result.command,
            isNotNull,
            reason: '"$phrase" is offered for ${capability.id} but is '
                '${result.outcome}',
          );
          expect(
            result.command!.action,
            capability.id,
            reason: '"$phrase" is offered for ${capability.id} but means '
                '${result.command!.action}',
          );
        }
      }
    });

    test('one phrase is offered by exactly one capability', () {
      final seen = <String, String>{};
      for (final capability in kCapabilities) {
        for (final phrase in phrasesOf(capability)) {
          expect(
            seen[phrase],
            isNull,
            reason: '"$phrase" is offered by both ${seen[phrase]} and '
                '${capability.id}',
          );
          seen[phrase] = capability.id;
        }
      }
    });

    test('a capability that offers phrasing says which section it is in', () {
      for (final capability in kCapabilities) {
        if (phrasesOf(capability).isEmpty) continue;
        expect(
          capability.helpGroup,
          isNotNull,
          reason: '${capability.id} offers a phrase but no section, so the '
              'help answer would silently drop it',
        );
      }
    });

    test('every section a capability names is one the answer prints', () {
      for (final capability in kCapabilities) {
        final group = capability.helpGroup;
        if (group == null) continue;
        expect(
          kHelpGroups,
          contains(group),
          reason: '${capability.id} is filed under "$group", which the help '
              'answer never prints',
        );
      }
    });

    test('a section holds only capabilities that are really in it', () {
      for (final group in kHelpGroups) {
        final inGroup = helpCapabilitiesIn(group);
        expect(
          inGroup.map((c) => c.id).toSet().length,
          inGroup.length,
          reason: '$group lists a capability twice',
        );
        for (final capability in inGroup) {
          expect(capability.helpGroup, group);
          expect(phrasesOf(capability), isNotEmpty);
        }
      }
      // Every offered capability is reachable from some section, so the
      // answer cannot omit one by accident.
      final reached = {for (final c in helpCapabilities) c.id};
      final offering = {
        for (final c in kCapabilities)
          if (phrasesOf(c).isNotEmpty) c.id,
      };
      expect(reached, offering);
    });

    test('every offered section is in exactly one area', () {
      // The areas are how the short answer is organised. A section no area
      // covers is one the summary never mentions and no area lists in full —
      // reachable only by asking about it by name, which is how the
      // hand-written wall fell behind. The entry point's own group is the
      // exception: it is the question, not a part of the answer.
      final covered = <String, String>{};
      for (final area in kHelpAreas) {
        expect(area.groups, isNotEmpty, reason: area.name);
        expect(area.name.trim(), isNotEmpty, reason: area.name);
        expect(area.question.trim(), isNotEmpty, reason: area.name);
        for (final group in area.groups) {
          expect(
            kHelpGroups,
            contains(group),
            reason: '${area.name} claims "$group", which is no section',
          );
          expect(
            covered[group],
            isNull,
            reason: '"$group" is claimed by both ${covered[group]} and '
                '${area.name}',
          );
          covered[group] = area.name;
        }
        expect(
          helpCapabilitiesInArea(area),
          isNotEmpty,
          reason: '${area.name} covers nothing to offer',
        );
      }
      for (final group in kHelpGroups) {
        if (group == kHelpEntryGroup || helpCapabilitiesIn(group).isEmpty) {
          continue;
        }
        expect(covered[group], isNotNull, reason: '"$group" is in no area');
      }
    });

    test('every offered section has a headline the summary can show', () {
      for (final group in kHelpGroups) {
        final headline = helpHeadline(group);
        if (helpCapabilitiesIn(group).isEmpty) {
          expect(headline, isNull, reason: '$group offers nothing');
          continue;
        }
        expect(headline, isNotNull, reason: group);
        expect(headline!.helpGroup, group, reason: group);
        expect(phrasesOf(headline), isNotEmpty, reason: group);
        // The headline the summary prints is a phrase the registry offers, so
        // the short answer can only show something that really parses.
        expect(
          [
            for (final capability in helpCapabilitiesIn(group))
              for (final phrase in phrasesOf(capability)) phrase,
          ],
          contains(headline.example ?? phrasesOf(headline).first),
          reason: group,
        );
      }
    });
  });

  group('platform gating', () {
    test('a phone advertises the same actions it always did', () {
      expect(
        defaultCapabilitiesFor('android').map((c) => c.id).toSet(),
        _phoneActions,
      );
    });

    test('every desktop advertises the same actions it always did', () {
      for (final platform in ['linux', 'windows', 'macos']) {
        expect(
          defaultCapabilitiesFor(platform).map((c) => c.id).toSet(),
          _desktopActions,
          reason: platform,
        );
      }
    });

    test('an unknown platform falls back to the desktop set', () {
      expect(
        defaultCapabilitiesFor('other').map((c) => c.id).toSet(),
        _desktopActions,
      );
    });

    test('a phone-only action is never offered by a desktop', () {
      for (final id in [
        AgentActions.callPlace,
        AgentActions.messageSend,
        AgentActions.alarmSet,
        AgentActions.flashlightToggle,
      ]) {
        expect(capabilityFor(id)!.platforms, isNot(contains('linux')));
        expect(capabilityFor(id)!.platforms, contains('android'));
      }
    });

    test('a locally-answered action is advertised by no device', () {
      for (final id in [
        AgentActions.mathCalc,
        AgentActions.tellJoke,
        AgentActions.memoryRecall,
      ]) {
        expect(
          capabilityFor(id)!.isDeviceExecutable,
          isFalse,
          reason: id,
        );
        expect(defaultCapabilitiesFor('android').map((c) => c.id), isNot(contains(id)));
        expect(defaultCapabilitiesFor('linux').map((c) => c.id), isNot(contains(id)));
      }
    });
  });
}
