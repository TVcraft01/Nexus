// How much memory this device has, and which model that buys.
//
// Two models are on offer and they are not the same product: 470 MB answers in
// a second or two and drops the action JSON when the instruction gets long,
// while 770 MB is noticeably slower and follows it. A user on their first run
// has no way to know which trade they are making, so the app makes the first
// guess for them — from the one fact that predicts it well, how much RAM the
// device has.
//
// The probe is deliberately not the only answer: a device that will not say
// gets the small model, because a wrong recommendation *down* costs a less
// clever answer and a wrong recommendation *up* costs the user most of a
// minute of download on a phone that may not be able to run it.
library;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, debugPrint, visibleForTesting;

import 'llm.dart' show totalRamBytes;
import 'on_device_model.dart';

/// The RAM above which the bigger model is the one the app recommends.
///
/// Six gigabytes, because that is what the phones this app runs on actually
/// have: below it the 1B has to fight the operating system for room, and on a
/// borderline device the small model's speed is worth more than the 1B's
/// obedience. The comparison is strictly greater, so a 6 GB phone — which is
/// what an A25 has — is recommended the small model.
const int kComfortableRamBytes = 6 * 1024 * 1024 * 1024;

/// The device's total memory, in bytes, or null when nothing will say.
///
/// Android is asked through `device_info_plus`, which reads
/// `ActivityManager.MemoryInfo.totalMem` — the number the phone's own settings
/// screen shows, and the one a user can check this app's advice against.
/// Everything else falls back to [totalRamBytes], which is the reader
/// [DeviceCapabilities] already gates the on-device model on: one
/// implementation of "read /proc/meminfo", so the screen that recommends a
/// model and the check that decides whether a model is offered at all cannot
/// disagree about the same phone.
class DeviceMemory {
  /// A test seam in the shape the rest of the core uses: a widget or unit test
  /// states the device's RAM instead of asking the machine running the suite.
  @visibleForTesting
  static Future<int?> Function()? debugProbeOverride;

  /// Total bytes of RAM, or null for "this device did not say".
  ///
  /// Never throws: a first-run screen that cannot read the RAM still has a
  /// recommendation to make, and it is the safe one.
  static Future<int?> totalBytes() async {
    final override = debugProbeOverride;
    if (override != null) return override();

    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        final int megabytes = (await DeviceInfoPlugin().androidInfo)
            .physicalRamSize;
        // The plugin documents zero for "unknown" on the platforms it cannot
        // read; a model recommendation must not be built on a zero.
        if (megabytes > 0) return megabytes * 1024 * 1024;
      } on Object catch (error) {
        debugPrint('MEMORY: Android did not report RAM ($error)');
      }
    }

    return totalRamBytes();
  }

  /// [bytes] in the words the welcome screen uses: "8 GB", "6 GB", "512 MB".
  ///
  /// Rounded to whole gigabytes above one, because the exact byte count of a
  /// phone's RAM is not a fact the user chose or can act on — and null is
  /// "Could not tell", which is what the screen says instead of a number.
  static String label(int? bytes) {
    if (bytes == null || bytes <= 0) return 'Could not tell';
    if (bytes >= 1024 * 1024 * 1024) {
      final double gigabytes = bytes / (1024 * 1024 * 1024);
      return '${gigabytes.round()} GB';
    }
    return '${(bytes / (1024 * 1024)).round()} MB';
  }
}

/// The model to recommend for a device with [ramBytes] of memory.
///
/// Null — no answer from the device — is the small model. See
/// [kComfortableRamBytes] for why the guess is that way round.
OnDeviceModelChoice recommendedModel(int? ramBytes) {
  if (ramBytes == null) return OnDeviceModelChoice.qwen;
  return ramBytes > kComfortableRamBytes
      ? OnDeviceModelChoice.llama
      : OnDeviceModelChoice.qwen;
}

/// The sentence that makes the recommendation make sense, in one line: what
/// this device has, and what the app chose because of it.
///
/// One function rather than the same three sentences in the widget, because a
/// recommendation the user cannot audit is a recommendation they have to trust
/// blindly — and this is the audit.
String recommendationReason(int? ramBytes, OnDeviceModelChoice choice) {
  final String memory = DeviceMemory.label(ramBytes);
  if (ramBytes == null) {
    return 'Nexus could not read this device\'s memory, so it picked the '
        'smaller model — you can change this any time in Settings.';
  }
  if (choice == OnDeviceModelChoice.llama) {
    return '$memory of memory is enough for the smarter model, which is '
        'better at the phone actions Nexus can run for you.';
  }
  return '$memory of memory is a better fit for the smaller, faster model — '
      'the bigger one can be chosen in Settings.';
}
