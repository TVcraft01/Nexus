// The Nexus Bridge: one loopback HTTP surface that speaks the three shapes a
// home automation stack already knows how to call.
//
// The shape is borrowed; the data is this device's own.
//
//  * Tailscale's `status --json` — `Self`, `Peer`, per-peer `Online`,
//    `TailscaleIPs`, `CurAddr`, `LastSeen` — because that is the vocabulary
//    already used to ask "is the other machine reachable, and by what path".
//    Nexus has no WireGuard tunnel and no DERP relay (every route it reports
//    is direct, so `Relay` is empty and there are no byte counters), so those
//    fields are omitted rather than filled with invented numbers.
//  * Home Assistant's REST API — `/api/`, `/api/states`, a bearer token,
//    `POST /api/services/<domain>/<service>` — so an automation, a dashboard
//    or `curl` can read this device's state and run an agent. There is no
//    state history here: `last_changed` and `last_updated` are the time of the
//    response, which is when the reading was taken.
//  * Siri App Intents — a named intent carrying a text slot, which a Shortcut
//    (or Siri itself, through one) invokes over `Get Contents of URL`. App
//    Intents are an Apple-only API and cannot be implemented in Dart, so the
//    portable half is what a Shortcut actually calls: `POST /intent` with
//    `{"name": ..., "agent": ...}`, and the same call as a query string for
//    the one-step version.
//
// Every route needs the bearer token, is answered only from a loopback
// address, and is refused when a web page (`Origin`) is behind the request.
// The bridge is a local control plane, not a LAN service: the mesh already
// owns that surface, with its own pairing keys.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'mesh_service.dart' show PeerReach;

/// One paired device as the bridge reports it. Built by the caller from the
/// mesh, so the bridge never reaches into mesh internals.
class BridgePeer {
  const BridgePeer({
    required this.id,
    required this.name,
    required this.platform,
    required this.address,
    required this.port,
    required this.online,
    required this.reach,
    this.addresses = const <String>[],
  });

  final String id;
  final String name;
  final String platform;
  final String address;
  final int port;
  final bool online;
  final PeerReach reach;
  final List<String> addresses;
}

/// The outcome of one agent run, in the terms the bridge reports it.
class BridgeRun {
  const BridgeRun({
    required this.agent,
    required this.ok,
    required this.result,
    required this.at,
  });

  final String agent;
  final bool ok;
  final String result;
  final DateTime at;
}

class NexusBridge {
  NexusBridge({
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.meshPort,
    required this.peers,
    required this.udpUnavailable,
    required this.runAgent,
    this.port = 0,
    String? token,
    Random? random,
  }) : token = token ?? newToken(random ?? Random.secure());

  final String deviceId;
  final String deviceName;
  final String platform;
  final int meshPort;

  /// The paired devices, read fresh on every request: a cached list would
  /// report a device as reachable long after it stopped answering.
  final List<BridgePeer> Function() peers;

  /// Whether this device's UDP discovery socket cannot receive. Settings says
  /// the same thing in words; this is the machine-readable half.
  final bool Function() udpUnavailable;

  /// Runs one stored agent now, exactly as the dashboard's button does.
  final Future<BridgeRun> Function(String agent) runAgent;

  /// Preferred bind port. 0 lets the OS pick one; the caller remembers the port
  /// it got so the next launch keeps the URL an automation was given.
  final int port;

  final String token;

  HttpServer? _server;

  int get boundPort => _server?.port ?? 0;

  String get baseUrl => 'http://127.0.0.1:$boundPort';

  /// The intents this build answers, in the order a Shortcut menu shows them.
  static const List<String> intents = <String>['status', 'run_agent'];

  static String newToken(Random random) =>
      base64Url.encode(List<int>.generate(24, (_) => random.nextInt(256)))
          .replaceAll('=', '');

  /// Binds and serves. Throws when the loopback port cannot be taken at all —
  /// the caller decides whether a bridge is worth a launch error, and the app
  /// logs it instead of failing to start.
  Future<int> start() async {
    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    } on SocketException {
      if (port == 0) rethrow;
      // The remembered port went to something else. An OS-chosen one keeps the
      // bridge available, and the new port is written back by the caller.
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    }
    _server = server;
    server.listen((HttpRequest request) => unawaited(_handle(request)));
    return server.port;
  }

  Future<void> stop() async {
    final HttpServer? server = _server;
    _server = null;
    await server?.close(force: true);
  }

  // ---------------------------------------------------------------------
  // Routing
  // ---------------------------------------------------------------------

  Future<void> _handle(HttpRequest request) async {
    final HttpResponse response = request.response;
    try {
      if (!_fromLoopback(request)) {
        await _json(response, HttpStatus.forbidden, <String, dynamic>{
          'message': '403: Forbidden',
          'error': 'local connections only',
        });
        return;
      }
      if (!_authorized(request)) {
        response.headers.set(HttpHeaders.wwwAuthenticateHeader, 'Bearer');
        await _json(response, HttpStatus.unauthorized, <String, dynamic>{
          'message': '401: Unauthorized',
        });
        return;
      }
      if (_foreignOrigin(request)) {
        await _json(response, HttpStatus.forbidden, <String, dynamic>{
          'message': '403: Forbidden',
          'error': 'a web page cannot drive the bridge',
        });
        return;
      }
      await _route(request, response);
    } on FormatException catch (error) {
      await _json(response, HttpStatus.badRequest, <String, dynamic>{
        'message': '400: Bad Request',
        'error': error.message,
      });
    } catch (error) {
      // The response may already be closed by a write that failed mid-body.
      try {
        await _json(response, HttpStatus.internalServerError, <String, dynamic>{
          'message': '500: Internal Server Error',
          'error': '$error',
        });
      } catch (_) {}
    }
  }

  Future<void> _route(HttpRequest request, HttpResponse response) async {
    final List<String> segments = request.uri.pathSegments;
    if (segments.isEmpty) {
      await _json(response, HttpStatus.notFound, _notFound());
      return;
    }
    final String head = segments.first;

    // GET /status — Tailscale's shape.
    if (head == 'status' && segments.length == 1) {
      if (!_isGet(request)) return _methodNotAllowed(response, 'GET');
      await _json(response, HttpStatus.ok, _status());
      return;
    }

    // GET /api/ and GET /api/states[/<entity_id>] — Home Assistant's shape.
    if (head == 'api') {
      if (segments.length == 1) {
        if (!_isGet(request)) return _methodNotAllowed(response, 'GET');
        await _json(response, HttpStatus.ok, <String, dynamic>{
          'message': 'API running.',
        });
        return;
      }
      if (segments[1] == 'states') {
        if (!_isGet(request)) return _methodNotAllowed(response, 'GET');
        if (segments.length == 2) {
          await _json(response, HttpStatus.ok, _states());
          return;
        }
        if (segments.length == 3) {
          final Map<String, dynamic>? state = _stateById(segments[2]);
          if (state == null) {
            await _json(response, HttpStatus.notFound, _notFound());
            return;
          }
          await _json(response, HttpStatus.ok, state);
          return;
        }
      }
      if (segments.length == 4 && segments[1] == 'services') {
        if (request.method != 'POST') {
          return _methodNotAllowed(response, 'POST');
        }
        await _service(request, response, segments[2], segments[3]);
        return;
      }
      await _json(response, HttpStatus.notFound, _notFound());
      return;
    }

    // /intent — what a Shortcut calls.
    if (head == 'intent' && segments.length == 1) {
      if (request.method != 'POST' && request.method != 'GET') {
        return _methodNotAllowed(response, 'GET, POST');
      }
      await _intent(request, response);
      return;
    }

    await _json(response, HttpStatus.notFound, _notFound());
  }

  /// Home Assistant's service-call path, with this app's one real domain.
  Future<void> _service(
    HttpRequest request,
    HttpResponse response,
    String domain,
    String service,
  ) async {
    if (domain != 'nexus' || service != 'run_agent') {
      await _json(response, HttpStatus.notFound, <String, dynamic>{
        'message': '404: Not Found',
        'error': 'the only service is nexus.run_agent',
      });
      return;
    }
    final Map<String, dynamic> body = await _body(request);
    final Object? agent = body['agent'];
    if (agent is! String || agent.trim().isEmpty) {
      await _json(response, HttpStatus.badRequest, <String, dynamic>{
        'message': '400: Bad Request',
        'error': 'a run_agent call needs "agent": the stored agent\'s name',
      });
      return;
    }
    await _run(response, agent.trim());
  }

  /// A named intent with its slot. `GET /intent?name=status` is the one-step
  /// Shortcut; `POST /intent` is the same call with a JSON body.
  Future<void> _intent(HttpRequest request, HttpResponse response) async {
    final Map<String, String> args = <String, String>{};
    if (request.method == 'POST') {
      final Map<String, dynamic> body = await _body(request);
      for (final MapEntry<String, dynamic> entry in body.entries) {
        final Object? value = entry.value;
        if (value is String) args[entry.key] = value;
      }
    } else {
      request.uri.queryParameters.forEach((key, value) => args[key] = value);
    }
    final String name = (args['name'] ?? args['intent'] ?? '').trim();
    if (name.isEmpty) {
      await _json(response, HttpStatus.badRequest, <String, dynamic>{
        'message': '400: Bad Request',
        'error': 'an intent call needs "name"',
        'intents': intents,
      });
      return;
    }
    if (name == 'status') {
      await _json(response, HttpStatus.ok, <String, dynamic>{
        'ok': true,
        'name': name,
        'reply': _spokenStatus(),
      });
      return;
    }
    if (name == 'run_agent') {
      final String agent = (args['agent'] ?? '').trim();
      if (agent.isEmpty) {
        await _json(response, HttpStatus.badRequest, <String, dynamic>{
          'message': '400: Bad Request',
          'error': 'the run_agent intent needs "agent"',
        });
        return;
      }
      await _run(response, agent);
      return;
    }
    await _json(response, HttpStatus.notFound, <String, dynamic>{
      'message': '404: Not Found',
      'error': 'unknown intent "$name"',
      'intents': intents,
    });
  }

  Future<void> _run(HttpResponse response, String agent) async {
    try {
      final BridgeRun run = await runAgent(agent);
      await _json(response, HttpStatus.ok, <String, dynamic>{
        'agent': run.agent,
        'ok': run.ok,
        'result': run.result,
        'at': _stamp(run.at),
      });
    } on Exception catch (error) {
      // A refusal is the user's to act on ("no agent by that name", "all
      // agents are halted"), which is a 400, not a broken bridge.
      await _json(response, HttpStatus.badRequest, <String, dynamic>{
        'message': '400: Bad Request',
        'error': '$error',
      });
    }
  }

  // ---------------------------------------------------------------------
  // Tailscale's status shape
  // ---------------------------------------------------------------------

  Map<String, dynamic> _status() {
    final List<BridgePeer> list = peers();
    final Map<String, dynamic> peerMap = <String, dynamic>{};
    for (final BridgePeer peer in list) {
      peerMap[peer.id] = _tailscalePeer(peer);
    }
    return <String, dynamic>{
      'Version': '1.0',
      'BackendState': 'Running',
      'Self': <String, dynamic>{
        'ID': deviceId,
        'HostName': deviceName,
        // No MagicDNS suffix exists for a Nexus device, and inventing one
        // would make a resolver try to use it.
        'DNSName': '',
        'OS': platform,
        'Online': true,
        'TailscaleIPs': const <String>[],
      },
      'Peer': peerMap,
      // What Tailscale's schema has no room for: how Nexus found each peer,
      // and whether its own discovery socket can hear anything.
      'Nexus': <String, dynamic>{
        'meshPort': meshPort,
        'udpDiscovery': udpUnavailable() ? 'unavailable' : 'working',
        'peersOnline': list.where((BridgePeer peer) => peer.online).length,
      },
    };
  }

  Map<String, dynamic> _tailscalePeer(BridgePeer peer) => <String, dynamic>{
    'ID': peer.id,
    'HostName': peer.name,
    'DNSName': '',
    'OS': peer.platform,
    'Online': peer.online,
    'TailscaleIPs': peer.addresses.isEmpty
        ? <String>[peer.address]
        : peer.addresses,
    'CurAddr': peer.address.isEmpty ? '' : '${peer.address}:${peer.port}',
    // Every route Nexus reports is direct; it has no relay to name.
    'Relay': '',
    'Active': peer.online,
    'LastSeen': peer.online
        ? _stamp(DateTime.now())
        : '0001-01-01T00:00:00Z',
    'NexusReach': _reachWord(peer.reach),
  };

  // ---------------------------------------------------------------------
  // Home Assistant's state shape
  // ---------------------------------------------------------------------

  List<Map<String, dynamic>> _states() {
    final DateTime now = DateTime.now();
    final List<Map<String, dynamic>> states = <Map<String, dynamic>>[
      _state(
        entityId: 'sensor.nexus_udp_discovery',
        state: udpUnavailable() ? 'off' : 'on',
        attributes: <String, dynamic>{
          'friendly_name': 'Nexus UDP discovery',
          'device_class': 'connectivity',
        },
        at: now,
      ),
      _state(
        entityId: 'sensor.nexus_peers_online',
        state: '${peers().where((BridgePeer p) => p.online).length}',
        attributes: <String, dynamic>{
          'friendly_name': 'Nexus peers online',
          'unit_of_measurement': 'devices',
          'icon': 'mdi:lan-connect',
        },
        at: now,
      ),
      _state(
        entityId: 'sensor.nexus_mesh_port',
        state: '$meshPort',
        attributes: <String, dynamic>{
          'friendly_name': 'Nexus mesh port',
          'icon': 'mdi:ethernet',
        },
        at: now,
      ),
    ];
    final Set<String> used = <String>{
      for (final Map<String, dynamic> state in states) '${state['entity_id']}',
    };
    for (final BridgePeer peer in peers()) {
      final String base = 'device_tracker.${_slug(peer.name)}';
      String id = base;
      var suffix = 2;
      while (!used.add(id)) {
        id = '${base}_$suffix';
        suffix++;
      }
      states.add(
        _state(
          entityId: id,
          state: peer.online ? 'home' : 'not_home',
          attributes: <String, dynamic>{
            'friendly_name': peer.name,
            'source_type': 'router',
            'ip': peer.address,
            'port': peer.port,
            'platform': peer.platform,
            'addresses': peer.addresses,
            'reach': _reachWord(peer.reach),
            'nexus_id': peer.id,
          },
          at: now,
        ),
      );
    }
    return states;
  }

  Map<String, dynamic>? _stateById(String entityId) {
    for (final Map<String, dynamic> state in _states()) {
      if (state['entity_id'] == entityId) return state;
    }
    return null;
  }

  /// One Home Assistant state object. `last_changed` and `last_updated` are the
  /// time of the response: Nexus keeps no state history, so a value that did
  /// not change still reports the moment it was read.
  Map<String, dynamic> _state({
    required String entityId,
    required String state,
    required Map<String, dynamic> attributes,
    required DateTime at,
  }) => <String, dynamic>{
    'entity_id': entityId,
    'state': state,
    'attributes': attributes,
    'last_changed': _stamp(at),
    'last_updated': _stamp(at),
    'context': <String, dynamic>{
      'id': 'nexus',
      'parent_id': null,
      'user_id': null,
    },
  };

  // ---------------------------------------------------------------------
  // Wording shared with Settings
  // ---------------------------------------------------------------------

  /// The same three phrases Settings shows, so an automation's log and the app
  /// never describe the same peer differently.
  static String _reachWord(PeerReach reach) => switch (reach) {
    PeerReach.udp => 'found via UDP',
    PeerReach.tcp => 'found via TCP',
    PeerReach.unreachable => 'not reachable',
  };

  /// What the `status` intent says out loud — a sentence a Shortcut can show or
  /// Siri can read back.
  String _spokenStatus() {
    // The same words the mesh's own status line uses — and the same reason it
    // avoids "is unavailable", which `platform_gap_test` reserves for claims
    // that this platform cannot do something at all.
    final String head = udpUnavailable()
        ? 'UDP discovery unavailable here, so devices are found over TCP.'
        : 'UDP discovery is working.';
    final List<BridgePeer> list = peers();
    if (list.isEmpty) return '$head No devices are paired yet.';
    final List<String> rows = <String>[
      for (final BridgePeer peer in list) '${peer.name}: ${_reachWord(peer.reach)}',
    ];
    return '$head ${rows.join('; ')}.';
  }

  // ---------------------------------------------------------------------
  // Request plumbing
  // ---------------------------------------------------------------------

  static bool _isGet(HttpRequest request) => request.method == 'GET';

  Future<void> _methodNotAllowed(HttpResponse response, String allow) async {
    response.headers.set(HttpHeaders.allowHeader, allow);
    await _json(response, HttpStatus.methodNotAllowed, <String, dynamic>{
      'message': '405: Method Not Allowed',
      'error': 'use $allow',
    });
  }

  Map<String, dynamic> _notFound() => <String, dynamic>{
    'message': '404: Not Found',
  };

  static bool _fromLoopback(HttpRequest request) {
    final InternetAddress? from = request.connectionInfo?.remoteAddress;
    return from != null && from.isLoopback;
  }

  bool _authorized(HttpRequest request) {
    final String? header = request.headers.value(
      HttpHeaders.authorizationHeader,
    );
    if (header != null && header.startsWith('Bearer ')) {
      if (_same(token, header.substring(7).trim())) return true;
    }
    // The one-step Shortcut carries the token in the URL: a Shortcut has a
    // header field, but the query form is what makes the whole call one line.
    final String? query = request.uri.queryParameters['token'];
    return query != null && _same(token, query);
  }

  /// A page in the user's browser must not be able to POST here. The token
  /// already stops it; this names the reason and refuses the case outright.
  static bool _foreignOrigin(HttpRequest request) {
    final String? origin = request.headers.value('origin');
    if (origin == null || origin.isEmpty) return false;
    final Uri? uri = Uri.tryParse(origin);
    if (uri == null) return true;
    final String host = uri.host.toLowerCase();
    return !(host == '127.0.0.1' ||
        host == 'localhost' ||
        host == '::1' ||
        host == '[::1]');
  }

  Future<Map<String, dynamic>> _body(HttpRequest request) async {
    final String text = await utf8.decoder.bind(request).join();
    if (text.trim().isEmpty) return <String, dynamic>{};
    final String contentType = request.headers.contentType?.mimeType ?? '';
    if (contentType.contains('json') || text.trimLeft().startsWith('{')) {
      final Object? decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      throw const FormatException('the body must be a JSON object');
    }
    return <String, dynamic>{
      for (final MapEntry<String, String> field
          in Uri.splitQueryString(text).entries)
        field.key: field.value,
    };
  }

  Future<void> _json(
    HttpResponse response,
    int status,
    Object body,
  ) async {
    response
      ..statusCode = status
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      ..headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }

  static String _stamp(DateTime at) => at.toUtc().toIso8601String();

  /// A Home Assistant entity id's name part: lower case, one underscore per run
  /// of anything that is not a letter or a digit.
  static String _slug(String text) {
    final StringBuffer out = StringBuffer();
    var pendingUnderscore = false;
    for (final int code in text.toLowerCase().codeUnits) {
      final bool alphanumeric =
          (code >= 0x61 && code <= 0x7a) || (code >= 0x30 && code <= 0x39);
      if (alphanumeric) {
        if (pendingUnderscore && out.isNotEmpty) out.write('_');
        pendingUnderscore = false;
        out.writeCharCode(code);
      } else {
        pendingUnderscore = true;
      }
    }
    final String slug = out.toString();
    return slug.isEmpty ? 'device' : slug;
  }

  /// Compares two secrets without returning early on the first differing byte,
  /// so the comparison itself does not say how much of a guess was right.
  static bool _same(String expected, String given) {
    if (expected.length != given.length) return false;
    var difference = 0;
    for (var i = 0; i < expected.length; i++) {
      difference |= expected.codeUnitAt(i) ^ given.codeUnitAt(i);
    }
    return difference == 0;
  }
}
