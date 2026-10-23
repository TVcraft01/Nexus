// The secret this device shows in its pairing QR, and the one it checks when a
// file arrives.
//
// The mesh's pairing codes (XXXX-XXXX) were built for a handshake this front
// end does not run: they are short enough to type, and derived twice from the
// code and a nonce. A file transfer needs a key both sides already have, kept
// across restarts, and never sent over the network — so this is a separate,
// long random token, shown once in the QR and stored by the scanner as the
// device's [PairedDevice.code].
//
// Stable per install on purpose. A token regenerated at launch would make every
// pairing stop authenticating the moment either phone was restarted, and the
// failure would look like a network problem.
//
// It is a *device* token rather than a per-pair token for a smaller reason than
// it looks: the shell's pairing is one-way today (the scanner learns the
// shower's code, the shower never learns the scanner's), so the one secret both
// ends can agree on is the one on the displayed QR. A sender proves it saw that
// QR; the receiver checks it knows its own token. A per-pair secret needs the
// handshake that the mesh will bring, not a second store invented here.
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

/// Key the token is stored under. Named here because a test reads it back.
const String kPairTokenKey = 'pair_transfer_token';

/// 32 random bytes, base64url without padding — 43 characters, which is long
/// enough to be a key and short enough to keep the QR from growing a third row
/// of modules.
String generatePairToken([Random? random]) {
  final Random rng = random ?? Random.secure();
  final List<int> bytes = List<int>.generate(32, (_) => rng.nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
}

/// This device's transfer token, read once and kept for the process.
class PairToken {
  PairToken._();

  static String? _memo;
  static Future<String>? _loading;

  /// The token, loading or creating it on first use.
  ///
  /// Never fails: a platform with no preferences plugin (a widget test, a
  /// desktop without the store) answers a token generated for this run. That
  /// token still authenticates both sides of a transfer made during the same
  /// run, which is exactly what a test needs and all a phone without storage
  /// could honestly offer.
  static Future<String> current() {
    final String? ready = _memo;
    if (ready != null) return Future<String>.value(ready);
    return _loading ??= _load();
  }

  /// The token if it is already in memory — for a synchronous caller that
  /// cannot await (the QR payload builder when it has one).
  static String? get peek => _memo;

  static Future<String> _load() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? stored = prefs.getString(kPairTokenKey);
      if (stored != null && stored.length >= 16) {
        _memo = stored;
        return stored;
      }
      final String fresh = generatePairToken();
      await prefs.setString(kPairTokenKey, fresh);
      _memo = fresh;
      return fresh;
    } catch (error) {
      debugPrint('PAIR TOKEN: no preferences store ($error)');
      final String fresh = _memo ??= generatePairToken();
      return fresh;
    } finally {
      _loading = null;
    }
  }

  /// Tests only: forget the token, so the next read sees a fresh store.
  @visibleForTesting
  static void debugReset() {
    _memo = null;
    _loading = null;
  }
}
