import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/cable_pairing.dart';

void main() {
  group('parseDevicesOutput', () {
    test('returns attached, authorized devices', () {
      final output = 'List of devices attached\n'
          'R5CX73XFGKW\tdevice usb:1-2 product:sm-s928b\n'
          'emulator-5554\tdevice product:sdk_gphone64\n';
      expect(CablePairing.parseDevicesOutput(output), ['R5CX73XFGKW', 'emulator-5554']);
    });

    test('ignores unauthorized and offline devices', () {
      final output = 'List of devices attached\n'
          'R5CX73XFGKW\tdevice\n'
          'DEADBEEF\tunauthorized\n'
          'EMULATOR1\toffline\n';
      expect(CablePairing.parseDevicesOutput(output), ['R5CX73XFGKW']);
    });

    test('returns empty for no devices or empty output', () {
      expect(CablePairing.parseDevicesOutput('List of devices attached\n\n'), isEmpty);
      expect(CablePairing.parseDevicesOutput(''), isEmpty);
    });
  });

  group('linuxSetupScript', () {
    test('produces a runnable script mentioning install and pairing', () {
      final script = CablePairing.linuxSetupScript();
      expect(script, contains('#!/usr/bin/env bash'));
      expect(script, contains('nexus-linux-x64.tar.gz'));
      expect(script, contains('Enter a code'));
      // The script is for the *other* device; it must not contain our own
      // shell-expanded variables.
      expect(script, isNot(contains('Undefined name')));
    });
  });
}
