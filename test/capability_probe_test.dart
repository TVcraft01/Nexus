import 'dart:io';

import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/capability_probe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('dev.nexus.nexus/device');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('RealCapabilityProbe', () {
    test('Android returns the native hardware feature set', () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return <String>[
              'camera',
              'mic',
              'filesystem',
              'display',
              'battery',
              'torch',
              'contacts',
              'serial-usb',
              'speech-in',
              'speech-out',
              'tts',
            ];
          });

      final result = await RealCapabilityProbe(platformOverride: 'android')
          .probe();

      expect(
        result,
        containsAll(<String>{
          'camera',
          'mic',
          'filesystem',
          'display',
          'battery',
          'torch',
          'contacts',
          'serial-usb',
          'speech-in',
          'speech-out',
          'tts',
        }),
      );
      expect(calls.map((call) => call.method), ['probeCapabilities']);
    });

    test(
      'Linux reports successful local checks and omits failed checks',
      () async {
        final result = await RealCapabilityProbe(
          platformOverride: 'linux',
          linuxChecks: {
            'filesystem': () async => true,
            'display': () async => false,
            'serial-port': () async => false,
            'ssh-client': () async => true,
            'ollama': () async => false,
          },
        ).probe();
        expect(result, {'filesystem', 'ssh-client'});
      },
    );

    test('Linux returns empty when every facility check fails', () async {
      final result = await RealCapabilityProbe(
        platformOverride: 'linux',
        linuxChecks: {
          'filesystem': () async => throw FileSystemException('unavailable'),
          'display': () async => false,
          'serial-port': () async => false,
          'ssh-client': () async => false,
          'ollama': () async => false,
        },
      ).probe();
      expect(result, isEmpty);
    });

    test('unknown platforms return empty without consulting Android', () async {
      var called = false;
      final result = await RealCapabilityProbe(
        platformOverride: 'satellite',
        androidProbe: () async {
          called = true;
          return {'camera'};
        },
      ).probe();
      expect(result, isEmpty);
      expect(called, isFalse);
    });

    test('a platform probe exception fails closed to empty', () async {
      final result = await RealCapabilityProbe(
        platformOverride: 'android',
        androidProbe: () async => throw StateError('probe unavailable'),
      ).probe();
      expect(result, isEmpty);
    });
  });

  test(
    'FakeCapabilityProbe returns its injected capabilities by value',
    () async {
      final source = <String>{'camera'};
      final probe = FakeCapabilityProbe(source);
      source.add('mic');
      final result = await probe.probe();
      expect(result, {'camera'});
      result.add('display');
      expect(await probe.probe(), {'camera'});
    },
  );
}
