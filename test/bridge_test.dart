// The bridge is three borrowed shapes over this device's own state: Tailscale's
// status document, Home Assistant's states and service calls, and the named
// intent a Shortcut calls. These tests drive it over a real HTTP client on a
// real loopback socket — a handler that parses JSON but never answers a request
// would pass nothing here.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/mesh/bridge.dart';
import 'package:nexus/mesh/mesh_service.dart' show PeerReach;

List<BridgePeer> _twoPeers() => <BridgePeer>[
  const BridgePeer(
    id: 'pc',
    name: 'Study PC',
    platform: 'linux',
    address: '192.168.1.100',
    port: 51820,
    online: true,
    reach: PeerReach.tcp,
    addresses: <String>['192.168.1.100', '100.64.0.2'],
  ),
  const BridgePeer(
    id: 'tab',
    name: 'Kitchen tablet',
    platform: 'android',
    address: '192.168.1.9',
    port: 51820,
    online: false,
    reach: PeerReach.unreachable,
  ),
];

class _Reply {
  _Reply(this.status, this.body, this.headers);

  final int status;
  final Object? body;
  final HttpHeaders headers;

  Map<String, dynamic> get map => body as Map<String, dynamic>;
  List<dynamic> get list => body as List<dynamic>;
}

/// One running bridge plus the client that talks to it.
class _Rig {
  _Rig({
    String token = 'test-token',
    List<BridgePeer> Function()? peers,
    bool udp = false,
    Future<BridgeRun> Function(String agent)? runAgent,
  }) : bridge = NexusBridge(
         deviceId: 'phone-id',
         deviceName: 'Pixel',
         platform: 'android',
         meshPort: 51820,
         peers: peers ?? _twoPeers,
         udpUnavailable: () => udp,
         runAgent:
             runAgent ??
             (String agent) async => BridgeRun(
               agent: agent,
               ok: true,
               result: 'ran $agent',
               at: DateTime.utc(2026, 11, 9, 10, 30),
             ),
         token: token,
       );

  final NexusBridge bridge;
  final HttpClient _client = HttpClient();

  Future<void> start() async {
    await bridge.start();
  }

  Future<void> stop() async {
    _client.close(force: true);
    await bridge.stop();
  }

  Future<_Reply> send(
    String method,
    String path, {
    Object? body,
    String? token = 'test-token',
    String? origin,
  }) async {
    final HttpClientRequest request = await _client.openUrl(
      method,
      Uri.parse('${bridge.baseUrl}$path'),
    );
    if (token != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    if (origin != null) request.headers.set('origin', origin);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final HttpClientResponse response = await request.close();
    final String text = await utf8.decoder.bind(response).join();
    return _Reply(
      response.statusCode,
      text.trim().isEmpty ? null : jsonDecode(text),
      response.headers,
    );
  }
}

void main() {
  late _Rig rig;

  Future<_Rig> boot({
    List<BridgePeer> Function()? peers,
    bool udp = false,
    Future<BridgeRun> Function(String agent)? runAgent,
  }) async {
    rig = _Rig(peers: peers, udp: udp, runAgent: runAgent);
    await rig.start();
    addTearDown(rig.stop);
    return rig;
  }

  test('status speaks the Tailscale shape, with Nexus additions', () async {
    final _Rig rig = await boot();
    final _Reply reply = await rig.send('GET', '/status');
    expect(reply.status, 200);

    final Map<String, dynamic> self = reply.map['Self'] as Map<String, dynamic>;
    expect(self['HostName'], 'Pixel');
    expect(self['OS'], 'android');
    expect(self['Online'], true);
    // No overlay addresses and no MagicDNS name exist, and both are left empty
    // rather than invented.
    expect(self['TailscaleIPs'], isEmpty);
    expect(self['DNSName'], '');

    final Map<String, dynamic> peers =
        reply.map['Peer'] as Map<String, dynamic>;
    expect(peers.keys, containsAll(<String>['pc', 'tab']));

    final Map<String, dynamic> pc = peers['pc'] as Map<String, dynamic>;
    expect(pc['Online'], true);
    expect(pc['CurAddr'], '192.168.1.100:51820');
    expect(pc['TailscaleIPs'], <String>['192.168.1.100', '100.64.0.2']);
    // Every Nexus route is direct, so there is never a relay to name.
    expect(pc['Relay'], '');
    expect(pc['NexusReach'], 'found via TCP');

    final Map<String, dynamic> tab = peers['tab'] as Map<String, dynamic>;
    expect(tab['Online'], false);
    expect(tab['LastSeen'], '0001-01-01T00:00:00Z');
    expect(tab['NexusReach'], 'not reachable');

    final Map<String, dynamic> nexus =
        reply.map['Nexus'] as Map<String, dynamic>;
    expect(nexus['udpDiscovery'], 'working');
    expect(nexus['peersOnline'], 1);
    expect(nexus['meshPort'], 51820);

    // Nothing the schema does not know about is smuggled in as a number.
    expect(pc.containsKey('RxBytes'), isFalse);
    expect(pc.containsKey('TxBytes'), isFalse);
  });

  test('every route needs the token, and a query token works', () async {
    final _Rig rig = await boot();
    for (final String path in <String>[
      '/status',
      '/api/',
      '/api/states',
      '/intent?name=status',
    ]) {
      final _Reply reply = await rig.send('GET', path, token: null);
      expect(reply.status, 401, reason: path);
      expect(reply.map['message'], '401: Unauthorized');
      expect(
        reply.headers.value(HttpHeaders.wwwAuthenticateHeader),
        contains('Bearer'),
      );
    }

    final _Reply wrong = await rig.send('GET', '/status', token: 'nope');
    expect(wrong.status, 401);

    // What a one-step Shortcut sends: the token in the URL.
    final _Reply query = await rig.send(
      'GET',
      '/intent?name=status&token=test-token',
      token: null,
    );
    expect(query.status, 200);
    expect(query.map['reply'], contains('Study PC: found via TCP'));
  });

  test('states are Home Assistant\'s shape, one tracker per peer', () async {
    final _Rig rig = await boot();
    final _Reply reply = await rig.send('GET', '/api/states');
    expect(reply.status, 200);

    final Map<String, dynamic> byId = <String, dynamic>{
      for (final dynamic state in reply.list)
        (state as Map<String, dynamic>)['entity_id']: state,
    };

    expect(
      (byId['sensor.nexus_udp_discovery'] as Map<String, dynamic>)['state'],
      'on',
    );
    expect(
      (byId['sensor.nexus_peers_online'] as Map<String, dynamic>)['state'],
      '1',
    );

    final Map<String, dynamic> pc =
        byId['device_tracker.study_pc'] as Map<String, dynamic>;
    expect(pc['state'], 'home');
    final Map<String, dynamic> attributes =
        pc['attributes'] as Map<String, dynamic>;
    expect(attributes['friendly_name'], 'Study PC');
    expect(attributes['ip'], '192.168.1.100');
    expect(attributes['port'], 51820);
    expect(attributes['reach'], 'found via TCP');
    // The timestamps are present for clients that require them; Nexus has no
    // state history, so they are the time of this reading.
    expect(pc['last_changed'], isNotEmpty);
    expect(pc['context'], isA<Map<String, dynamic>>());

    final Map<String, dynamic> tab =
        byId['device_tracker.kitchen_tablet'] as Map<String, dynamic>;
    expect(tab['state'], 'not_home');

    // The list is served with the entities it was built from, not a second
    // read that could disagree with it.
    expect(byId.length, reply.list.length);
  });

  test('two peers with one name get two entity ids', () async {
    final _Rig rig = await boot(
      peers: () => <BridgePeer>[
        ..._twoPeers(),
        const BridgePeer(
          id: 'pc2',
          name: 'Study PC',
          platform: 'windows',
          address: '192.168.1.101',
          port: 51820,
          online: true,
          reach: PeerReach.udp,
        ),
      ],
    );
    final _Reply reply = await rig.send('GET', '/api/states');
    final List<String> ids = <String>[
      for (final dynamic state in reply.list)
        (state as Map<String, dynamic>)['entity_id'] as String,
    ];
    expect(ids.where((String id) => id.startsWith('device_tracker.')).length, 3);
    expect(ids.toSet().length, ids.length);
    expect(ids, contains('device_tracker.study_pc_2'));
  });

  test('one state by id, and a 404 for one that does not exist', () async {
    final _Rig rig = await boot();
    final _Reply found = await rig.send(
      'GET',
      '/api/states/device_tracker.study_pc',
    );
    expect(found.status, 200);
    expect(found.map['entity_id'], 'device_tracker.study_pc');

    final _Reply missing = await rig.send(
      'GET',
      '/api/states/device_tracker.garage_door',
    );
    expect(missing.status, 404);
    expect(missing.map['message'], '404: Not Found');
  });

  test('a service call runs an agent', () async {
    final _Rig rig = await boot();
    final _Reply reply = await rig.send(
      'POST',
      '/api/services/nexus/run_agent',
      body: <String, dynamic>{'agent': 'Wi-Fi check'},
    );
    expect(reply.status, 200);
    expect(reply.map['agent'], 'Wi-Fi check');
    expect(reply.map['ok'], true);
    expect(reply.map['result'], 'ran Wi-Fi check');
    expect(reply.map['at'], '2026-11-09T10:30:00.000Z');
  });

  test('a refused run is a 400, with the service\'s own sentence', () async {
    final _Rig rig = await boot(
      runAgent: (String agent) async =>
          throw Exception('no agent by the name “$agent”'),
    );
    final _Reply reply = await rig.send(
      'POST',
      '/api/services/nexus/run_agent',
      body: <String, dynamic>{'agent': 'Nope'},
    );
    expect(reply.status, 400);
    expect(reply.map['error'], contains('no agent by the name'));
  });

  test('a service call that names no agent is a 400', () async {
    final _Rig rig = await boot();
    final _Reply reply = await rig.send(
      'POST',
      '/api/services/nexus/run_agent',
      body: <String, dynamic>{},
    );
    expect(reply.status, 400);
    expect(reply.map['error'], contains('"agent"'));
  });

  test('only nexus.run_agent exists, and it says so', () async {
    final _Rig rig = await boot();
    final _Reply reply = await rig.send(
      'POST',
      '/api/services/nexus/explode',
      body: <String, dynamic>{},
    );
    expect(reply.status, 404);
    expect(reply.map['error'], contains('nexus.run_agent'));
  });

  test('the status intent answers in words a Shortcut can read', () async {
    final _Rig rig = await boot();
    final _Reply reply = await rig.send('GET', '/intent?name=status');
    expect(reply.status, 200);
    expect(reply.map['ok'], true);
    expect(reply.map['reply'], contains('UDP discovery is working'));
    expect(reply.map['reply'], contains('Kitchen tablet: not reachable'));
  });

  test('the run_agent intent works over POST and over the query string', () async {
    final _Rig rig = await boot();
    final _Reply post = await rig.send(
      'POST',
      '/intent',
      body: <String, dynamic>{'name': 'run_agent', 'agent': 'Wi-Fi check'},
    );
    expect(post.status, 200);
    expect(post.map['ok'], true);

    final _Reply get = await rig.send(
      'GET',
      '/intent?name=run_agent&agent=Wi-Fi%20check',
    );
    expect(get.status, 200);
    expect(get.map['agent'], 'Wi-Fi check');
  });

  test('an unknown intent lists the ones that exist', () async {
    final _Rig rig = await boot();
    final _Reply reply = await rig.send(
      'POST',
      '/intent',
      body: <String, dynamic>{'name': 'make_coffee'},
    );
    expect(reply.status, 404);
    expect(reply.map['intents'], NexusBridge.intents);
  });

  test('an intent with no name is a 400', () async {
    final _Rig rig = await boot();
    final _Reply reply = await rig.send(
      'POST',
      '/intent',
      body: <String, dynamic>{},
    );
    expect(reply.status, 400);
    expect(reply.map['error'], contains('"name"'));
  });

  test('a GET-only route refuses POST and names the method to use', () async {
    final _Rig rig = await boot();
    final _Reply reply = await rig.send('POST', '/status');
    expect(reply.status, 405);
    expect(reply.headers.value(HttpHeaders.allowHeader), 'GET');
  });

  test('a web page cannot drive the bridge', () async {
    final _Rig rig = await boot();
    final _Reply reply = await rig.send(
      'POST',
      '/api/services/nexus/run_agent',
      body: <String, dynamic>{'agent': 'Wi-Fi check'},
      origin: 'http://evil.example',
    );
    expect(reply.status, 403);
    expect(reply.map['error'], contains('web page'));
  });

  test('UDP discovery unavailable is reported in all three shapes', () async {
    final _Rig rig = await boot(udp: true);
    final _Reply status = await rig.send('GET', '/status');
    expect(
      (status.map['Nexus'] as Map<String, dynamic>)['udpDiscovery'],
      'unavailable',
    );

    final _Reply states = await rig.send('GET', '/api/states');
    final Map<String, dynamic> sensor = states.list
        .cast<Map<String, dynamic>>()
        .firstWhere(
          (Map<String, dynamic> state) =>
              state['entity_id'] == 'sensor.nexus_udp_discovery',
        );
    expect(sensor['state'], 'off');

    final _Reply intent = await rig.send('GET', '/intent?name=status');
    expect(intent.map['reply'], contains('over TCP'));
  });

  test('the port is remembered by the caller, so a restart keeps the URL', () async {
    final _Rig first = _Rig();
    await first.start();
    final int port = first.bridge.boundPort;
    expect(port, greaterThan(0));
    await first.stop();

    // A second bridge asked for that exact port gets it: this is the path a
    // launch takes with the stored value.
    final NexusBridge second = NexusBridge(
      deviceId: 'phone-id',
      deviceName: 'Pixel',
      platform: 'android',
      meshPort: 51820,
      peers: _twoPeers,
      udpUnavailable: () => false,
      runAgent: (String agent) async =>
          BridgeRun(agent: agent, ok: true, result: '', at: DateTime.now()),
      port: port,
    );
    await second.start();
    addTearDown(second.stop);
    expect(second.boundPort, port);
    expect(second.baseUrl, 'http://127.0.0.1:$port');
  });
}
