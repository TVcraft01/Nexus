import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'identity.dart';

/// Everything Nexus persists on one device lives in a single JSON file in the
/// app's private data directory. Nothing is ever sent anywhere; this is the
/// device's own copy of its identity, its pairing secrets, and its history.
class NexusStore {
  File? _file;
  final String? explicitPath;
  Map<String, dynamic> _data = {};

  /// [explicitPath] is used by tests so no plugin is needed; production code
  /// resolves the app-support directory automatically.
  NexusStore({this.explicitPath});

  DeviceInfo get identity {
    final raw = _data['identity'] as Map<String, dynamic>?;
    if (raw != null) return DeviceInfo.fromJson(raw);
    return DeviceInfo(id: 'unknown', name: 'My device', platform: 'other');
  }

  void setIdentity(DeviceInfo info) {
    _data['identity'] = info.toJson();
  }

  int get port => ((_data['settings'] as Map<String, dynamic>?)?['port'] as num?)?.toInt() ?? 51820;

  set port(int value) => _settings()['port'] = value;

  bool get clipboardSync => ((_data['settings'] as Map<String, dynamic>?)?['clipboardSync'] as bool?) ?? true;

  set clipboardSync(bool value) => _settings()['clipboardSync'] = value;

  bool get broadcastDiscovery =>
      ((_data['settings'] as Map<String, dynamic>?)?['broadcastDiscovery'] as bool?) ?? true;

  set broadcastDiscovery(bool value) => _settings()['broadcastDiscovery'] = value;

  Map<String, dynamic> _settings() =>
      _data.putIfAbsent('settings', () => <String, dynamic>{});

  List<Map<String, dynamic>> get pairedDevices =>
      ((_data['paired'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();

  void upsertPaired(Map<String, dynamic> device) {
    final list = _data.putIfAbsent('paired', () => <Map<String, dynamic>>[])
        as List;
    final idx = list.indexWhere((e) => e['id'] == device['id']);
    if (idx >= 0) {
      list[idx] = device;
    } else {
      list.add(device);
    }
  }

  void removePaired(String deviceId) {
    final list = _data['paired'] as List?;
    list?.removeWhere((e) => e['id'] == deviceId);
  }

  /// Recently-seen device addresses, so discovery can say hello directly to
  /// known devices even when multicast is filtered by the router.
  List<Map<String, dynamic>> get neighbors =>
      ((_data['neighbors'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();

  void upsertNeighbor(String id, String address, int port, String name) {
    final list = _data.putIfAbsent('neighbors', () => <Map<String, dynamic>>[])
        as List;
    final now = DateTime.now().toIso8601String();
    final idx = list.indexWhere((e) => e['id'] == id);
    if (idx >= 0) {
      list[idx] = {'id': id, 'address': address, 'port': port, 'name': name, 'lastSeen': now};
    } else {
      list.add({'id': id, 'address': address, 'port': port, 'name': name, 'lastSeen': now});
    }
    // Keep it small: the most recent 12 devices, dropping anything not seen
    // within the last day (a stale address is worse than none — a phone that
    // was switched off overnight is re-discovered when it announces again).
    final cutoff = DateTime.now().subtract(const Duration(hours: 24));
    list.removeWhere((e) {
      final seen = DateTime.tryParse(e['lastSeen'] as String? ?? '');
      return seen != null && seen.isBefore(cutoff);
    });
    if (list.length > 12) list.removeRange(12, list.length);
  }

  /// Drops stored neighbors not seen in the last 24h. Called on startup so
  /// ghost devices from an earlier session disappear instead of being
  /// re-greeted forever.
  void pruneStaleNeighbors() {
    final list = _data['neighbors'] as List?;
    if (list == null) return;
    final cutoff = DateTime.now().subtract(const Duration(hours: 24));
    list.removeWhere((e) {
      if (e is! Map) return false;
      final seen = DateTime.tryParse(e['lastSeen'] as String? ?? '');
      return seen != null && seen.isBefore(cutoff);
    });
  }

  Future<void> load() async {
    _file ??= await _defaultFile();
    if (await _file!.exists()) {
      try {
        final text = await _file!.readAsString();
        _data = (jsonDecode(text) as Map<String, dynamic>?) ?? {};
      } catch (_) {
        // A corrupted store must never brick the app — start fresh but keep
        // the file around so the user can inspect it.
        _data = {};
      }
    }
  }

  Future<void> save() async {
    final file = _file ??= await _defaultFile();
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(_data), flush: true);
    await tmp.rename(file.path);
  }

  Future<File> _defaultFile() async {
    if (explicitPath != null) {
      return File(explicitPath!);
    }
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}nexus${Platform.pathSeparator}state.json');
  }
}
