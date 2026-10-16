import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/services/icon_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A switcher that answers the way a device would, and records what it was
/// asked to do — so the tests below can pin the *decisions* (which mode, how
/// often, what happens when Android says no) without an emulator.
class _ScriptedSwitcher implements LauncherIconSwitcher {
  _ScriptedSwitcher({this.on, this.accepts = true, this.error, this.supported = true});

  /// What the launcher is showing, as far as this fake is concerned.
  IconMode? on;

  /// Whether the platform accepts a switch.
  bool accepts;

  /// When set, the platform throws this instead of answering.
  Object? error;

  @override
  final bool supported;

  /// Every mode the service actually pushed, in order.
  final List<IconMode> applied = <IconMode>[];

  /// How often the service asked before switching.
  int reads = 0;

  @override
  Future<IconMode?> current() async {
    reads++;
    final Object? thrown = error;
    if (thrown != null) throw thrown;
    return on;
  }

  @override
  Future<bool> apply(IconMode mode) async {
    final Object? thrown = error;
    if (thrown != null) throw thrown;
    applied.add(mode);
    if (accepts) on = mode;
    return accepts;
  }
}

/// Runs [body] with the platform forced. The binding insists this debug value
/// is put back before the test body ends — a tear-down is too late — so it is
/// reset here rather than registered.
Future<void> asPlatform(TargetPlatform platform, Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('IconMode', () {
    test('every mode survives a round trip through its token', () {
      for (final IconMode mode in IconMode.values) {
        expect(IconMode.fromToken(mode.token), mode);
      }
    });

    test('an unknown token falls back instead of throwing', () {
      expect(IconMode.fromToken('sepia'), IconMode.auto);
      expect(IconMode.fromToken(null), IconMode.auto);
      expect(IconMode.fromToken('sepia', fallback: IconMode.light), IconMode.light);
    });

    test('auto follows the system theme, the other two do not', () {
      expect(IconMode.auto.resolve(Brightness.dark), IconMode.dark);
      expect(IconMode.auto.resolve(Brightness.light), IconMode.light);
      expect(IconMode.light.resolve(Brightness.dark), IconMode.light);
      expect(IconMode.dark.resolve(Brightness.light), IconMode.dark);
    });
  });

  group('SharedPrefsIconModeStore', () {
    test('reads the mode written under the icon_mode key', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        SharedPrefsIconModeStore.key: 'dark',
      });
      expect(await SharedPrefsIconModeStore().read(), IconMode.dark);
    });

    test('writes the mode under the icon_mode key', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SharedPrefsIconModeStore().write(IconMode.light);
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('icon_mode'), 'light');
    });

    test('an empty store and a junk value both answer null/auto, never throw', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      expect(await SharedPrefsIconModeStore().read(), isNull);
      SharedPreferences.setMockInitialValues(<String, Object>{
        SharedPrefsIconModeStore.key: 'chartreuse',
      });
      expect(await SharedPrefsIconModeStore().read(), IconMode.auto);
    });
  });

  group('IconService', () {
    testWidgets('a stored mode is applied on attach', (tester) async {
      final _ScriptedSwitcher switcher = _ScriptedSwitcher(on: IconMode.light);
      final IconService service = IconService(
        store: MemoryIconModeStore(),
        switcher: switcher,
      );
      addTearDown(service.detach);
      await service.setMode(IconMode.dark);
      expect(switcher.applied, <IconMode>[IconMode.dark]);
    });

    testWidgets('auto picks the mark the system theme asks for', (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final _ScriptedSwitcher switcher = _ScriptedSwitcher(on: IconMode.light);
      final IconService service = IconService(
        store: MemoryIconModeStore(),
        switcher: switcher,
      );
      addTearDown(service.detach);
      await service.setMode(IconMode.auto);
      expect(service.mode, IconMode.auto);
      expect(switcher.applied, <IconMode>[IconMode.dark]);
    });

    testWidgets('a theme flip switches the icon while auto is on', (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final _ScriptedSwitcher switcher = _ScriptedSwitcher(on: IconMode.light);
      final IconService service = IconService(
        store: MemoryIconModeStore(),
        switcher: switcher,
      );
      addTearDown(service.detach);
      await service.attach();
      expect(switcher.applied, isEmpty, reason: 'already wearing the right mark');

      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pump();
      expect(switcher.applied, <IconMode>[IconMode.dark]);
      // The choice is still Auto: the phone decided, the user did not.
      expect(service.mode, IconMode.auto);
    });

    testWidgets('an explicit mode ignores the system theme', (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final _ScriptedSwitcher switcher = _ScriptedSwitcher(on: IconMode.dark);
      final IconService service = IconService(
        store: MemoryIconModeStore(),
        switcher: switcher,
      );
      addTearDown(service.detach);
      await service.setMode(IconMode.light);
      expect(switcher.applied, <IconMode>[IconMode.light]);
    });

    testWidgets('the platform is asked before it is told anything', (tester) async {
      final _ScriptedSwitcher switcher = _ScriptedSwitcher(on: IconMode.light);
      final IconService service = IconService(
        store: MemoryIconModeStore(),
        switcher: switcher,
      );
      addTearDown(service.detach);
      await service.setMode(IconMode.light);
      expect(switcher.reads, greaterThan(0));
      expect(
        switcher.applied,
        isEmpty,
        reason: 'a switch must not re-touch a component that already shows the '
            'right icon: launchers redraw on every change, and some restart the '
            'app\'s task for it',
      );
    });

    testWidgets('a refusal is reported and the choice is still remembered', (tester) async {
      final MemoryIconModeStore store = MemoryIconModeStore();
      final _ScriptedSwitcher switcher = _ScriptedSwitcher(
        on: IconMode.light,
        accepts: false,
      );
      final IconService service = IconService(store: store, switcher: switcher);
      addTearDown(service.detach);
      await service.setMode(IconMode.dark);
      expect(service.failure, isNotNull);
      expect(await store.read(), IconMode.dark);
    });

    testWidgets('a platform error becomes a reported failure, not a crash', (tester) async {
      final _ScriptedSwitcher switcher = _ScriptedSwitcher(
        on: IconMode.light,
        error: PlatformException(code: 'ICON_UNKNOWN_MODE', message: 'no alias'),
      );
      final IconService service = IconService(
        store: MemoryIconModeStore(),
        switcher: switcher,
      );
      addTearDown(service.detach);
      await service.setMode(IconMode.dark);
      expect(service.failure, 'no alias');
    });

    testWidgets('a build with no channel says so rather than pretending', (tester) async {
      final _ScriptedSwitcher switcher = _ScriptedSwitcher(
        on: IconMode.light,
        error: MissingPluginException('no handler'),
      );
      final IconService service = IconService(
        store: MemoryIconModeStore(),
        switcher: switcher,
      );
      addTearDown(service.detach);
      await service.setMode(IconMode.dark);
      expect(service.failure, 'This build has no icon channel');
    });

    testWidgets('a platform that cannot switch is left alone', (tester) async {
      final _ScriptedSwitcher switcher = _ScriptedSwitcher(
        on: IconMode.light,
        supported: false,
      );
      final IconService service = IconService(
        store: MemoryIconModeStore(),
        switcher: switcher,
      );
      addTearDown(service.detach);
      await service.setMode(IconMode.dark);
      expect(service.switchingSupported, isFalse);
      expect(switcher.applied, isEmpty);
      expect(service.failure, isNull);
    });

    testWidgets('two overlapping choices settle on the last one, once', (
      tester,
    ) async {
      // The platform starts on dark, and the user taps Light then changes their
      // mind to Dark before either switch has run. The launcher must end up on
      // dark — and must not be churned through light on the way, which is what
      // settling to the *latest* desire rather than to each request buys.
      final MemoryIconModeStore store = MemoryIconModeStore();
      final _ScriptedSwitcher switcher = _ScriptedSwitcher(on: IconMode.dark);
      final IconService service = IconService(store: store, switcher: switcher);
      addTearDown(service.detach);
      final Future<void> first = service.setMode(IconMode.light);
      final Future<void> second = service.setMode(IconMode.dark);
      await Future.wait(<Future<void>>[first, second]);
      expect(service.mode, IconMode.dark);
      expect(await store.read(), IconMode.dark);
      expect(await service.platformMode(), IconMode.dark);
      expect(switcher.applied, isEmpty);
    });

    testWidgets('attach is idempotent and reports what the launcher shows', (
      tester,
    ) async {
      final _ScriptedSwitcher switcher = _ScriptedSwitcher(on: IconMode.light);
      final IconService service = IconService(
        store: MemoryIconModeStore(),
        switcher: switcher,
      );
      addTearDown(service.detach);
      await service.attach();
      await service.attach();
      expect(await service.platformMode(), IconMode.light);
    });
  });

  group('ChannelLauncherIconSwitcher', () {
    const MethodChannel channel = MethodChannel('dev.nexus.nexus/app_icon');
    final List<MethodCall> calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            calls.add(call);
            return switch (call.method) {
              'currentIcon' => 'dark',
              'setIcon' => true,
              _ => null,
            };
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    testWidgets('sends the mode under the name MainActivity answers', (tester) async {
      await asPlatform(TargetPlatform.android, () async {
        final ChannelLauncherIconSwitcher switcher = ChannelLauncherIconSwitcher();
        expect(switcher.supported, isTrue);
        expect(await switcher.apply(IconMode.dark), isTrue);
      });
      expect(calls.single.method, 'setIcon');
      expect(calls.single.arguments, <String, Object?>{'mode': 'dark'});
    });

    testWidgets('reads which alias is on and maps the token back', (tester) async {
      await asPlatform(TargetPlatform.android, () async {
        expect(await ChannelLauncherIconSwitcher().current(), IconMode.dark);
      });
      expect(calls.single.method, 'currentIcon');
    });

    testWidgets('everywhere but Android it declines without calling anything', (tester) async {
      await asPlatform(TargetPlatform.linux, () async {
        final ChannelLauncherIconSwitcher switcher = ChannelLauncherIconSwitcher();
        expect(switcher.supported, isFalse);
        expect(await switcher.current(), isNull);
        expect(await switcher.apply(IconMode.dark), isFalse);
      });
      expect(calls, isEmpty);
    });

    testWidgets('a token the platform does not know lands on auto, not on a crash', (
      tester,
    ) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async => 'plaid');
      await asPlatform(TargetPlatform.android, () async {
        expect(await ChannelLauncherIconSwitcher().current(), IconMode.auto);
      });
    });
  });
}
