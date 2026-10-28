// On-device peer probe — the PC half of the 3a/3b/3c hardware checklist.
//
// Run as its own `flutter test` process. It reads the phone's QR payload from
// `/tmp/nexus_probe/phone.json` (decoded off the Devices screen with zbarimg),
// pairs with the phone's mesh, then walks three stages, each waiting for a
// hand-off file so the human side can screenshot the phone between them:
//
//   stage 1  unsigned ping  -> the phone should show
//                             "Ping from Rehearsal PC (unverified)"
//            wait for go2
//   stage 2  signed ping    -> no badge, HTTP 200
//            wait for go3
//   stage 3  agent request  -> the phone's approval card (music.search)
//
// Not part of the normal suite (leading underscore is not a test glob).
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/file_transfer_service.dart';
import 'package:nexus/mesh/mesh_service.dart';

const String _dir = '/tmp/nexus_probe';
const String _probeId = 'probe-pc-1';
const String _probeName = 'Rehearsal PC';

String _path(String name) => '$_dir/$name';

void _log(String line) {
  final File file = File(_path('log.txt'));
  file.writeAsStringSync(
    '${DateTime.now().toIso8601String()} $line\n',
    mode: FileMode.append,
  );
  // ignore: avoid_print
  print('PROBE $line');
}

/// Waits for a hand-off file the shell side touches.
Future<void> _await(String name, {String? previous}) async {
  // Do not carry a stale go file from an earlier stage into this one.
  if (previous != null) {
    final File old = File(_path(previous));
    if (old.existsSync()) old.deleteSync();
  }
  final DateTime deadline = DateTime.now().add(const Duration(minutes: 4));
  while (!File(_path(name)).existsSync()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for $name');
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  _log('saw $name');
}

String _nonce() {
  final Random random = Random.secure();
  return base64Url.encode(
    List<int>.generate(18, (_) => random.nextInt(256)),
  );
}

Future<String> _sign(String key, String canonical) async {
  final Mac mac = await Hmac.sha256().calculateMac(
    utf8.encode(canonical),
    secretKey: SecretKey(utf8.encode(key)),
  );
  return base64Encode(mac.bytes);
}

/// One POST to `/nexus/ping`, signed only when [token] is given.
Future<int> _ping({
  required String host,
  required int port,
  required String senderId,
  required String senderName,
  String? token,
}) async {
  final HttpClient client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 3);
  try {
    final HttpClientRequest request = await client
        .postUrl(
          Uri(scheme: 'http', host: host, port: port, path: kNexusPingPath),
        )
        .timeout(const Duration(seconds: 5));
    request.headers
      ..set(kHeaderDevice, senderId)
      ..set(kHeaderName, senderName);
    if (token != null) {
      final String nonce = _nonce();
      final int ts = DateTime.now().millisecondsSinceEpoch;
      request.headers
        ..set(kHeaderNonce, nonce)
        ..set(kHeaderTimestamp, '$ts')
        ..set(
          kHeaderSignature,
          await _sign(
            token,
            pingSignaturePayload(senderId: senderId, nonce: nonce, ts: ts),
          ),
        );
    }
    request.contentLength = 0;
    final HttpClientResponse response = await request.close().timeout(
      const Duration(seconds: 8),
    );
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('probe: pair with the phone, ping it twice, send it one action',
      () async {
    Directory(_dir).createSync(recursive: true);
    File(_path('log.txt')).writeAsStringSync('');
    for (final String name in ['go1', 'go2', 'go3', 'paired', 'done']) {
      final File f = File(_path(name));
      if (f.existsSync()) f.deleteSync();
    }

    final Map<String, dynamic> phone =
        jsonDecode(File(_path('phone.json')).readAsStringSync())
            as Map<String, dynamic>;
    final String host = phone['address'] as String;
    final int transferPort = int.parse('${phone['port']}');
    final int meshPort = int.parse('${phone['mesh_port']}');
    final String phoneId = phone['device_id'] as String;
    final String token = phone['code'] as String;

    final NexusStore store =
        NexusStore(explicitPath: _path('probe_store.json'))..port = 53555;
    await store.load();
    store.pairingEnabled = true;
    await store.save();

    final MeshService mesh = MeshService(
      identity: DeviceInfo(
        id: _probeId,
        name: _probeName,
        platform: 'linux',
      ),
      store: store,
      onlineWindow: const Duration(seconds: 5),
      visibleWindow: const Duration(seconds: 5),
      heartbeatInterval: const Duration(seconds: 2),
      connectTimeout: const Duration(seconds: 2),
    );
    await mesh.start();
    _log('mesh up on ${mesh.port}');

    try {
      // A restart of this probe reuses the pairing it already made: the phone
      // keeps the row, so only a first run needs the mesh code from the QR.
      Future<void> awaitPairing() async {
        final DateTime deadline =
            DateTime.now().add(const Duration(seconds: 12));
        while (mesh.pairedDevices.isEmpty &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }

      await awaitPairing();
      if (mesh.pairedDevices.isEmpty) {
        final result = await mesh.pairWith(
          address: host,
          port: meshPort,
          code: phone['mesh_code'] as String,
        );
        _log('pair ok=${result.ok} error=${result.error}');
        expect(result.ok, isTrue, reason: result.error);
        await awaitPairing();
      }
      _log('paired=${mesh.pairedDevices.map((d) => '${d.id}/${d.name}').join(',')}');
      expect(mesh.pairedDevices, isNotEmpty);
      File(_path('paired')).writeAsStringSync('ok');

      // The action stage. A session key lives only inside the run that
      // handshook, so a probe reusing a stored pairing sends frames the phone
      // cannot decrypt — a property of this harness, not of the app. This is
      // therefore run straight after the pairing above.
      Future<void> agents() async {
        await _await('go3');
        final AgentRequest request = AgentRequest(
          requestId: 'probe-${DateTime.now().millisecondsSinceEpoch}',
          target: phoneId,
          action: AgentActions.musicSearch,
          arguments: const {'query': 'hotline bling'},
          approval: AgentApproval.approved,
        );
        _log('agent request ${request.requestId} -> $phoneId');
        final AgentDispatchResult? reply =
            await mesh.sendAgentRequest(phoneId, request);
        final Map<String, dynamic> record = {
          'status': reply?.status.name ?? 'none',
          'message': reply?.message ?? '',
          'at': DateTime.now().toIso8601String(),
        };
        File(_path('step3.json')).writeAsStringSync(jsonEncode(record));
        _log('agent reply ${jsonEncode(record)}');
        File(_path('done')).writeAsStringSync('ok');
      }

      if (Platform.environment['NEXUS_PROBE_SKIP_PINGS'] == '1') {
        await agents();
        return;
      }

      // --- stage 1: unsigned ------------------------------------------------
      await _await('go1');
      final int unsigned = await _ping(
        host: host,
        port: transferPort,
        senderId: _probeId,
        senderName: _probeName,
      );
      _log('unsigned ping -> $unsigned');
      File(_path('step1.txt')).writeAsStringSync('$unsigned');
      await _await('go2');

      // --- stage 2: signed with the token the QR carried --------------------
      final int signed = await _ping(
        host: host,
        port: transferPort,
        senderId: _probeId,
        senderName: _probeName,
        token: token,
      );
      _log('signed ping -> $signed');
      File(_path('step2.txt')).writeAsStringSync('$signed');
      await agents();
    } finally {
      await mesh.stop();
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
