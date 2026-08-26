import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart'
    show getApplicationDocumentsDirectory;

import '../mesh/mesh_service.dart';

/// A temporary but honest record of everything the assistant is asked and
/// how it answered, appended as JSON lines to shared storage so the raw
/// questions can be read later — to improve matching and spot bugs without
/// guessing. Buffered and size-capped so it stays easy on the battery.
class QueryLog {
  QueryLog._();
  static final QueryLog i = QueryLog._();

  static const _maxBytes = 512 * 1024;
  @visibleForTesting
  static Duration flushDelay = const Duration(seconds: 3);
  File? _file;
  final List<String> _pending = [];
  Timer? _flushTimer;
  bool _writing = false;

  Future<File?> _resolve() async {
    final cached = _file;
    if (cached != null) return cached;
    try {
      Directory? dir;
      final shared = await MeshService.androidSharedRoot();
      if (shared != null) {
        dir = Directory('$shared/Nexus');
      } else {
        dir = await getApplicationDocumentsDirectory();
      }
      await dir.create(recursive: true);
      final f = File('${dir.path}${Platform.pathSeparator}assistant_log.jsonl');
      // One rolling page: past the cap we start fresh (the .1 keeps the old).
      if (await f.exists() && await f.length() > _maxBytes) {
        await f.rename('${f.path}.1');
      }
      return _file = f;
    } catch (_) {
      return null; // logging must never break the assistant
    }
  }

  /// Records one event. Fire-and-forget by design.
  void write(String kind, Map<String, dynamic> data) {
    _pending.add(
      jsonEncode({'ts': DateTime.now().toIso8601String(), 'kind': kind, ...data}),
    );
    _flushTimer ??= Timer(flushDelay, _flush);
    if (_pending.length >= 8) unawaited(_flush());
  }

  /// Cancels pending work so a test can end without dangling timers.
  @visibleForTesting
  void resetForTest() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _pending.clear();
  }

  void ask(String input, String status, String route, String detail) =>
      write('ask', {'input': input, 'status': status, 'route': route, 'detail': detail});

  void call(String contact, String outcome, {List<String>? candidates}) =>
      write('call', {'contact': contact, 'outcome': outcome, '?candidates': candidates});

  void learned(String phrase, String meaning) =>
      write('learned', {'phrase': phrase, 'meaning': meaning});

  void remote(String from, String action, String approval, String detail) =>
      write('remote', {'from': from, 'action': action, 'approval': approval, 'detail': detail});

  Future<void> _flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_writing || _pending.isEmpty) return;
    _writing = true;
    final batch = List<String>.of(_pending);
    _pending.clear();
    try {
      final f = await _resolve();
      await f?.writeAsString(
        '${batch.join('\n')}\n',
        mode: FileMode.append,
        flush: false, // no fsync per line — battery over durability here
      );
    } catch (_) {
      // Never crash or nag for logging.
    }
    _writing = false;
    if (_pending.isNotEmpty && _flushTimer == null) {
      _flushTimer = Timer(flushDelay, _flush);
    }
  }
}
