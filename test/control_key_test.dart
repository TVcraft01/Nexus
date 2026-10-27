// The control key: a per-pair secret both sides derive from the pairing
// secret, so a ping can be signed in *both* directions without either device
// ever sending its transfer token.
//
// Two halves, tested where each lives. The derivation is pure crypto and is
// pinned here directly. The file link's use of it is pinned with two real
// listeners on loopback, because the interesting cases — a signature that is
// not the expected key, a replayed nonce, an old build that cannot sign — only
// exist once HTTP is involved.
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show debugPrint, debugPrintThrottled;
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/crypto.dart'
    show deriveControlKey, deriveControlKeyString, deriveSessionKey;
import 'package:nexus/core/identity.dart' show DeviceInfo;
import 'package:nexus/core/pair_invite.dart' show PairIdentity;
import 'package:nexus/core/paired_devices.dart';
import 'package:nexus/core/store.dart' show ControlPath, NexusStore;
import 'package:nexus/mesh/file_transfer_service.dart';
import 'package:nexus/mesh/mesh_service.dart' as mesh
    show MeshService, PairedDevice;

/// The id a ping actually carries: the sender's own identity, not a row id.
String get _me => PairIdentity.current.id;

/// The id this test uses for the receiver's row. It is deliberately *not* the
/// sender's own id: `ping` sends `PairIdentity.current.id`, and the row is only
/// the address book entry.
const String _senderIdForRows = 'kitchen-tablet-0000000000000000001';

/// One listener, its folder, and the row that points at it.
class _Link {
  _Link(this.service, this.folder);

  final FileTransferService service;
  final Directory folder;

  int get port => service.boundPort;

  /// The sender's row for this link. [token] is what a scan of its QR would
  /// have written; empty means the pairing never gave one.
  PairedDevice row({String token = ''}) => PairedDevice(
    id: _senderIdForRows,
    name: 'Kitchen tablet',
    publicKey: '',
    addresses: const <String>['127.0.0.1'],
    port: port,
    code: token,
  );

  Future<void> dispose() async {
    await service.stop();
    if (folder.existsSync()) folder.deleteSync(recursive: true);
  }
}

Future<_Link> _link({String token = ''}) async {
  final Directory folder = Directory.systemTemp.createTempSync('nexus-ctl-');
  final FileTransferService service = FileTransferService(
    port: 0,
    directory: () async => folder,
    token: token,
  );
  await service.start();
  expect(service.running, isTrue, reason: service.problem ?? 'no problem said');
  return _Link(service, folder);
}

/// One hand-built control request, for the parts of a request the client would
/// never send.
Future<int> _post(int port, String path, Map<String, String> headers) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.postUrl(
      Uri(scheme: 'http', host: '127.0.0.1', port: port, path: path),
    );
    headers.forEach(request.headers.set);
    request.contentLength = 0;
    final HttpClientResponse response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

Future<int> _freePort() async {
  final ServerSocket socket = await ServerSocket.bind(
    InternetAddress.loopbackIPv4,
    0,
  );
  final int port = socket.port;
  await socket.close();
  return port;
}

void main() {
  group('the control key is derived, not exchanged', () {
    test('both sides of a pair derive the same key', () async {
      final String fromA = await deriveControlKeyString(
        pairingSecret: 'paired-once-ABCD-2345',
        myId: 'device-a-000000000000000000000001',
        peerId: 'device-b-000000000000000000000002',
      );
      final String fromB = await deriveControlKeyString(
        pairingSecret: 'paired-once-ABCD-2345',
        myId: 'device-b-000000000000000000000002',
        peerId: 'device-a-000000000000000000000001',
      );

      expect(fromB, fromA, reason: 'ids are sorted, so order cannot matter');
    });

    test('the control key is not the session key', () async {
      // Same secret, same ids, different purpose. If these were equal a
      // control signature would be replayable as a channel frame.
      final List<int> control = await deriveControlKey(
        pairingSecret: 'shared',
        myId: 'a',
        peerId: 'b',
      );
      final List<int> session = await deriveSessionKey(
        pairingSecret: 'shared',
        myId: 'a',
        peerId: 'b',
      );

      expect(base64Encode(control), isNot(base64Encode(session)));
    });

    test('a re-pair, which mints a new secret, mints a new key', () async {
      final String before = await deriveControlKeyString(
        pairingSecret: 'code-from-the-first-pairing',
        myId: 'a',
        peerId: 'b',
      );
      final String after = await deriveControlKeyString(
        pairingSecret: 'code-from-the-second-pairing',
        myId: 'a',
        peerId: 'b',
      );

      expect(after, isNot(before));
    });
  });

  group('the mesh answers with a key only for a peer it paired', () {
    late NexusStore store;
    late mesh.MeshService service;
    late Directory folder;

    Future<void> startWith({
      required String peerId,
      required String secret,
    }) async {
      folder = Directory.systemTemp.createTempSync('nexus-mesh-ctl-');
      store = NexusStore(explicitPath: '${folder.path}/store.json');
      await store.load();
      store.port = await _freePort();
      await store.save();
      store.upsertPaired(
        mesh.PairedDevice(
          id: peerId,
          name: 'Ocean Phone',
          platform: 'android',
          address: '127.0.0.1',
          port: 51821,
          pairingSecret: secret,
        ).toJson(),
      );
      // Saved, because `MeshService.start` loads the store again — an in-memory
      // upsert would be wiped by the very call that is about to read it.
      await store.save();
      service = mesh.MeshService(
        identity: DeviceInfo(
          id: 'device-b-000000000000000000000002',
          name: 'Study laptop',
          platform: 'linux',
        ),
        store: store,
        connectTimeout: const Duration(milliseconds: 300),
      );
      await service.start();
      addTearDown(() async {
        await service.stop();
        if (folder.existsSync()) folder.deleteSync(recursive: true);
      });
    }

    test('a paired peer gives a key both sides can compute', () async {
      const String peerId = 'device-a-000000000000000000000001';
      await startWith(peerId: peerId, secret: 'ABCD-2345');

      final String? key = await service.controlKeyFor(peerId);
      final String expected = await deriveControlKeyString(
        pairingSecret: 'ABCD-2345',
        myId: 'device-b-000000000000000000000002',
        peerId: peerId,
      );

      expect(key, expected);
    });

    test('a peer the mesh never paired has no key', () async {
      await startWith(
        peerId: 'device-a-000000000000000000000001',
        secret: 'ABCD-2345',
      );

      expect(await service.controlKeyFor('somebody-else'), isNull);
    });

    test('a peer with no pairing secret has no key', () async {
      const String peerId = 'device-a-000000000000000000000001';
      await startWith(peerId: peerId, secret: '');

      expect(
        await service.controlKeyFor(peerId),
        isNull,
        reason: 'a shell-only row is exactly the legacy case',
      );
    });

    test('forgetting a device drops its key', () async {
      const String peerId = 'device-a-000000000000000000000001';
      await startWith(peerId: peerId, secret: 'ABCD-2345');
      expect(await service.controlKeyFor(peerId), isNotNull);

      await service.forgetDevice(peerId);

      expect(await service.controlKeyFor(peerId), isNull);
    });

    test('a version is remembered per peer, not for the mesh', () async {
      const String peerId = 'device-a-000000000000000000000001';
      await startWith(peerId: peerId, secret: 'ABCD-2345');

      service.debugNotePeerVersion(peerId, '1.0.4');

      expect(service.peerAppVersion(peerId), '1.0.4');
      expect(
        service.peerAppVersion('device-c-000000000000000000000003'),
        isNull,
        reason: 'a peer that never spoke must not inherit the last one heard',
      );
    });
  });

  group('the file link signs with the per-pair key when there is one', () {
    /// The key both sides of these tests hold, computed the way the mesh
    /// computes it and handed to the services directly.
    Future<String> pairKey() => deriveControlKeyString(
      pairingSecret: 'ABCD-2345',
      myId: 'device-a-000000000000000000000001',
      peerId: 'device-b-000000000000000000000002',
    );

    /// A receiver that knows the sender by name and answers [key] for it.
    Future<_Link> knowing(String? key, {String token = ''}) async {
      final _Link link = await _link(token: token);
      link.service.peerNameLookup = (String id) =>
          id == _me ? 'Kitchen tablet' : null;
      if (key != null) {
        link.service.peerControlKeyLookup = (String id) async =>
            id == _me ? key : null;
      }
      addTearDown(link.dispose);
      return link;
    }

    test('a ping signed with the pair key verifies', () async {
      final String key = await pairKey();
      final _Link receiver = await knowing(key);
      final _Link sender = await _link();
      addTearDown(sender.dispose);
      sender.service.peerControlKeyLookup = (String id) async => key;

      final Future<NexusPing> arriving = receiver.service.pings.first;
      final NexusRequestResult result = await sender.service.ping(
        // No token in the row at all: the signature can only have come from
        // the derived key.
        receiver.row(),
      );

      expect(result.ok, isTrue, reason: result.message);
      final NexusPing ping = await arriving.timeout(
        const Duration(seconds: 2),
      );
      expect(ping.verified, isTrue);
    });

    test('a sender with no key in the row and no mesh key goes unsigned', () async {
      final _Link receiver = await knowing(null);
      final _Link sender = await _link();
      addTearDown(sender.dispose);

      final Future<NexusPing> arriving = receiver.service.pings.first;
      await sender.service.ping(receiver.row());

      final NexusPing ping = await arriving.timeout(
        const Duration(seconds: 2),
      );
      expect(ping.verified, isFalse, reason: 'this is the legacy path');
      expect(ping.deviceName, 'Kitchen tablet');
    });

    test('a build from before this pass is still understood', () async {
      // The mixed-version case, which is every pairing in the field today: the
      // sender knows the receiver's transfer token and signs with it. The
      // receiver also has a mesh key here, and must still accept the token —
      // the older peer has nothing else to sign with, and refusing it would
      // turn a working ping into a 401.
      final String key = await pairKey();
      final _Link receiver = await knowing(
        key,
        token: 'receiver-transfer-token',
      );
      final _Link sender = await _link();
      addTearDown(sender.dispose);

      final Future<NexusPing> arriving = receiver.service.pings.first;
      final NexusRequestResult result = await sender.service.ping(
        receiver.row(token: 'receiver-transfer-token'),
      );

      expect(result.ok, isTrue, reason: result.message);
      final NexusPing ping = await arriving.timeout(
        const Duration(seconds: 2),
      );
      expect(ping.verified, isTrue);
    });

    test('a row token wins, so a receiver that cannot derive still verifies', () async {
      // An older receiver has no control key at all: it checks its own token and
      // nothing else. A sender that preferred the derived key would be refused
      // here, which is why the token is tried first.
      final String key = await pairKey();
      final _Link oldReceiver = await _link(token: 'older-receiver-token');
      addTearDown(oldReceiver.dispose);
      final _Link sender = await _link();
      addTearDown(sender.dispose);
      // The sender has a mesh key *and* a token in the row.
      sender.service.peerControlKeyLookup = (String id) async => key;

      final Future<NexusPing> arriving = oldReceiver.service.pings.first;
      final NexusRequestResult result = await sender.service.ping(
        oldReceiver.row(token: 'older-receiver-token'),
      );

      expect(result.ok, isTrue, reason: result.message);
      final NexusPing ping = await arriving.timeout(
        const Duration(seconds: 2),
      );
      expect(ping.verified, isTrue);
    });

    /// A receiver whose acceptances land in a store, the way `main()` wires it.
    Future<NexusStore> meteredInto(_Link link) async {
      final Directory folder = Directory.systemTemp.createTempSync(
        'nexus-meter-',
      );
      addTearDown(() {
        if (folder.existsSync()) folder.deleteSync(recursive: true);
      });
      final NexusStore store = NexusStore(
        explicitPath: '${folder.path}/store.json',
      );
      await store.load();
      link.service.onControl = store.noteControlPath;
      return store;
    }

    test('a ping proved by the pair key is counted on the derived path', () async {
      final String key = await pairKey();
      final _Link receiver = await knowing(key);
      final NexusStore store = await meteredInto(receiver);
      final _Link sender = await _link();
      addTearDown(sender.dispose);
      sender.service.peerControlKeyLookup = (String id) async => key;

      final Future<NexusPing> arriving = receiver.service.pings.first;
      await sender.service.ping(receiver.row());
      await arriving.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // The key that verified is named, not just "control worked": the token
      // path cannot be deleted on the strength of the derived path's traffic.
      expect(store.controlPathSeen(ControlPath.derived), 1);
      expect(store.controlPathSeen(ControlPath.token), 0);
      expect(store.controlPathSeen(ControlPath.unsigned), 0);
      expect(store.controlPathLast(ControlPath.derived), contains(_me));
    });

    test('a ping proved by the token is counted on the token path', () async {
      final String key = await pairKey();
      final _Link receiver = await knowing(
        key,
        token: 'receiver-transfer-token',
      );
      final NexusStore store = await meteredInto(receiver);
      final _Link sender = await _link();
      addTearDown(sender.dispose);

      final Future<NexusPing> arriving = receiver.service.pings.first;
      await sender.service.ping(receiver.row(token: 'receiver-transfer-token'));
      await arriving.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(store.controlPathSeen(ControlPath.token), 1);
      expect(store.controlPathSeen(ControlPath.derived), 0);
      expect(store.controlPathSeen(ControlPath.unsigned), 0);
    });

    test('a wrong signature is refused even when two keys are acceptable', () async {
      final String key = await pairKey();
      final _Link receiver = await knowing(
        key,
        token: 'receiver-transfer-token',
      );
      final int ts = DateTime.now().millisecondsSinceEpoch;

      final int status = await _post(
        receiver.port,
        kNexusPingPath,
        <String, String>{
          kHeaderDevice: _me,
          kHeaderName: 'Kitchen tablet',
          kHeaderNonce: 'forged',
          kHeaderTimestamp: '$ts',
          kHeaderSignature: base64Encode(List<int>.filled(32, 7)),
        },
      );

      expect(status, HttpStatus.unauthorized);
    });

    test('a replayed nonce is refused on the derived path too', () async {
      final String key = await pairKey();
      final _Link receiver = await knowing(key);
      final int ts = DateTime.now().millisecondsSinceEpoch;
      final String signature = await _signRaw(
        key,
        pingSignaturePayload(senderId: _me, nonce: 'reused', ts: ts),
      );
      final Map<String, String> headers = <String, String>{
        kHeaderDevice: _me,
        kHeaderName: 'Kitchen tablet',
        kHeaderNonce: 'reused',
        kHeaderTimestamp: '$ts',
        kHeaderSignature: signature,
      };

      expect(
        await _post(receiver.port, kNexusPingPath, headers),
        HttpStatus.ok,
      );
      expect(
        await _post(receiver.port, kNexusPingPath, headers),
        HttpStatus.unauthorized,
      );
    });

    test('an accepted unsigned ping is metered with the peer version', () async {
      final List<String> lines = <String>[];
      debugPrint = (String? message, {int? wrapWidth}) {
        lines.add(message ?? '');
      };
      addTearDown(() => debugPrint = debugPrintThrottled);

      final _Link receiver = await knowing(null);
      receiver.service.peerVersionLookup = (String id) =>
          id == _me ? '1.0.4' : null;
      final List<String> metered = <String>[];
      receiver.service.onControl =
          (ControlPath path, String id, String name, String v) {
            metered.add('${path.name}|$id|$name|$v');
          };

      final int status = await _post(receiver.port, kNexusPingPath, <String, String>{
        kHeaderDevice: _me,
        kHeaderName: 'Your bank',
      });

      expect(status, HttpStatus.ok);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        lines.where((String l) => l.startsWith('control: unsigned from')),
        <String>['control: unsigned from Kitchen tablet 1.0.4'],
      );
      expect(metered, <String>['unsigned|$_me|Kitchen tablet|1.0.4']);
    });

    test('a peer that never announced a version is metered as unknown', () async {
      final List<String> lines = <String>[];
      debugPrint = (String? message, {int? wrapWidth}) {
        lines.add(message ?? '');
      };
      addTearDown(() => debugPrint = debugPrintThrottled);

      final _Link receiver = await knowing(null);
      receiver.service.peerVersionLookup = (String id) => null;

      await _post(receiver.port, kNexusPingPath, <String, String>{
        kHeaderDevice: _me,
        kHeaderName: 'Your bank',
      });

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        lines.where((String l) => l.startsWith('control: unsigned from')),
        <String>['control: unsigned from Kitchen tablet unknown'],
      );
    });

    test('a signed ping still verifies with no mesh behind the link', () async {
      // The shipped rule before this pass, unchanged: the token in the row is
      // still a proof for a pairing the mesh never saw.
      final _Link receiver = await _link(token: 'receiver-token-0123456789');
      addTearDown(receiver.dispose);
      final _Link sender = await _link();
      addTearDown(sender.dispose);

      final Future<NexusPing> arriving = receiver.service.pings.first;
      await sender.service.ping(receiver.row(token: 'receiver-token-0123456789'));

      final NexusPing ping = await arriving.timeout(
        const Duration(seconds: 2),
      );
      expect(ping.verified, isTrue);
    });
  });

  group('control acceptances are counted where a release can read them', () {
    test('the count and the last one survive a reload', () async {
      final Directory folder = Directory.systemTemp.createTempSync(
        'nexus-count-',
      );
      addTearDown(() {
        if (folder.existsSync()) folder.deleteSync(recursive: true);
      });
      final String path = '${folder.path}/store.json';
      final NexusStore store = NexusStore(explicitPath: path);
      await store.load();

      store.noteUnsignedControl(_senderIdForRows, 'Kitchen tablet', '1.0.4');
      store.noteUnsignedControl(_senderIdForRows, 'Kitchen tablet', '1.0.4');
      await store.save();

      final NexusStore reloaded = NexusStore(explicitPath: path);
      await reloaded.load();
      expect(reloaded.unsignedControlSeen, 2);
      expect(
        reloaded.unsignedControlLast,
        'Kitchen tablet 1.0.4 ($_senderIdForRows)',
      );
    });

    test('a fresh store counts nothing', () async {
      final NexusStore store = NexusStore(
        explicitPath: '${Directory.systemTemp.path}/nexus-never-written.json',
      );
      await store.load();
      expect(store.unsignedControlSeen, 0);
      expect(store.unsignedControlLast, isEmpty);
      for (final ControlPath path in ControlPath.values) {
        expect(store.controlPathSeen(path), 0, reason: path.name);
      }
    });

    test('each path keeps its own count and its own last sender', () async {
      final Directory folder = Directory.systemTemp.createTempSync(
        'nexus-paths-',
      );
      addTearDown(() {
        if (folder.existsSync()) folder.deleteSync(recursive: true);
      });
      final String path = '${folder.path}/store.json';
      final NexusStore store = NexusStore(explicitPath: path);
      await store.load();

      store.noteControlPath(ControlPath.unsigned, 'id-u', 'Old phone', '0.9.0');
      store.noteControlPath(ControlPath.token, 'id-t', 'Scanned PC', '1.0.0');
      store.noteControlPath(ControlPath.token, 'id-t', 'Scanned PC', '1.0.0');
      store.noteControlPath(ControlPath.derived, 'id-d', 'Paired mac', '1.0.1');
      await store.save();

      final NexusStore reloaded = NexusStore(explicitPath: path);
      await reloaded.load();

      // Three separate questions, three separate answers: this is what makes
      // "delete the token path" a decision rather than a guess.
      expect(reloaded.controlPathSeen(ControlPath.unsigned), 1);
      expect(reloaded.controlPathSeen(ControlPath.token), 2);
      expect(reloaded.controlPathSeen(ControlPath.derived), 1);
      expect(
        reloaded.controlPathLast(ControlPath.token),
        'Scanned PC 1.0.0 (id-t)',
      );
      expect(reloaded.controlPathLast(ControlPath.derived), 'Paired mac 1.0.1 (id-d)');
      // The compatibility reader is the unsigned path, and only it.
      expect(reloaded.unsignedControlSeen, 1);
      expect(reloaded.unsignedControlLast, 'Old phone 0.9.0 (id-u)');
    });
  });
}

/// HMAC of one canonical string, so a test can send the same signed request
/// twice rather than only observing the ones the client builds.
Future<String> _signRaw(String key, String canonical) async {
  final Mac mac = await Hmac.sha256().calculateMac(
    utf8.encode(canonical),
    secretKey: SecretKey(utf8.encode(key)),
  );
  return base64Encode(mac.bytes);
}
