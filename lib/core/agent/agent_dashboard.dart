// The local-only dashboard: one page on 127.0.0.1 that shows every agent and
// lets the user start, pause, stop or run one.
//
// Local-only is enforced three ways, because "it binds loopback" alone is not
// the whole promise:
//
// 1. it binds `InternetAddress.loopbackIPv4`, so nothing off this PC can
//    reach it;
// 2. every request must also come from a loopback address, which refuses the
//    odd forwarding setup that presents an outside caller as local;
// 3. the path carries a random key made at launch. Without it, any web page in
//    the user's browser could POST to `http://127.0.0.1:PORT/stop` and stop
//    their agents — a page cannot guess a key it never saw. The key dies with
//    the process, like the URL itself.
//
// There is no framework here and no asset: one HTML page with inline styles,
// rendered from the store on each request, so what the page shows is what the
// service will act on.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'agent_records.dart';
import 'agent_service.dart';
import 'agent_store.dart';

class AgentDashboard {
  AgentDashboard({
    required this.service,
    AgentStore? store,
    this.port = 0,
    String? token,
    Random? random,
  }) : store = store ?? service.store,
       _token = token ?? _newToken(random ?? Random.secure());

  final AgentService service;
  final AgentStore store;

  /// Bind port; 0 lets the OS pick one, which is the only value the product
  /// uses — a fixed port would collide with whatever else is on it.
  final int port;

  final String _token;
  HttpServer? _server;
  String? _url;

  /// The URL to open, with its key. Null before [start].
  String? get url => _url;

  int get boundPort => _server?.port ?? 0;

  static String _newToken(Random random) {
    final List<int> bytes = List<int>.generate(18, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// Binds and serves. Throws when the port is taken — the caller decides
  /// whether a dashboard is worth an error, and the app logs it instead of
  /// failing the launch.
  Future<String> start() async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      port,
    );
    _server = server;
    _url = 'http://127.0.0.1:${server.port}/$_token/';
    server.listen((HttpRequest request) => unawaited(_handle(request)));
    return _url!;
  }

  Future<void> stop() async {
    final HttpServer? server = _server;
    _server = null;
    _url = null;
    await server?.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final HttpResponse response = request.response;
    try {
      final InternetAddress? from = request.connectionInfo?.remoteAddress;
      if (from == null || !from.isLoopback) {
        await _text(response, HttpStatus.forbidden, 'local connections only');
        return;
      }
      final List<String> segments = request.uri.pathSegments;
      if (segments.isEmpty || segments.first != _token) {
        // Same answer as a path that does not exist: the only way to learn
        // the key is to have been given the URL.
        await _text(response, HttpStatus.notFound, 'not found');
        return;
      }
      final String action = segments.length > 1 ? segments[1] : '';
      if (request.method == 'GET' && action.isEmpty) {
        await _html(response, _page());
        return;
      }
      if (request.method != 'POST') {
        response.headers.set(HttpHeaders.allowHeader, 'GET, POST');
        await _text(response, HttpStatus.methodNotAllowed, 'use POST');
        return;
      }
      await _act(request, response, action);
    } catch (error) {
      try {
        await _text(response, HttpStatus.internalServerError, '$error');
      } catch (_) {
        // The response was already closed; nothing left to say.
      }
    }
  }

  Future<void> _act(
    HttpRequest request,
    HttpResponse response,
    String action,
  ) async {
    final String body = await utf8.decoder.bind(request).join();
    final Map<String, String> fields = Uri.splitQueryString(
      body.trim().isEmpty ? '' : body,
    );
    final String name = (fields['name'] ?? '').trim();

    try {
      switch (action) {
        case 'start':
          await service.start(name);
        case 'pause':
          await service.pause(name);
        case 'stop':
          await service.stop(name);
        case 'run':
          await service.runNow(name);
        case 'halt':
          service.haltAll();
        case 'resume':
          service.resumeAgents();
        case 'usage':
          await store.setUsageOptIn(fields['on'] == 'yes');
        default:
          await _text(response, HttpStatus.notFound, 'not found');
          return;
      }
    } on AgentServiceError catch (error) {
      await _text(response, HttpStatus.badRequest, error.message);
      return;
    }

    response
      ..statusCode = HttpStatus.seeOther
      ..headers.set(HttpHeaders.locationHeader, '/$_token/')
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    await response.close();
  }

  Future<void> _html(HttpResponse response, String body) async {
    response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.write(body);
    await response.close();
  }

  Future<void> _text(HttpResponse response, int status, String body) async {
    response
      ..statusCode = status
      ..headers.contentType = ContentType.text
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.write(body);
    await response.close();
  }

  String get _base => '/$_token';

  String _page() {
    final List<AgentDefinition> agents = store.savedAgents;
    final String rows = agents.isEmpty
        ? '<tr><td colspan="6" class="empty">No agents yet. Ask Nexus to make '
              'one, for example “draft replies to my mail in my style”.</td></tr>'
        : agents.map(_row).join();
    final String usage = store.usageOptIn
        ? 'On — ${store.recordedUsage.length} entries kept on this PC. '
              'Nexus uses them to suggest working hours.'
        : 'Off. Nothing is recorded, so Nexus cannot suggest working hours.';
    final String haltBox = service.halted
        ? '<p class="halt">Halted. No agent starts, and a run in progress '
              'stops before its next step.</p>'
              '<form method="post" action="$_base/resume">'
              '<button>Clear the halt</button></form>'
        : '<form method="post" action="$_base/halt">'
              '<button>Halt all agents</button></form>';
    return '''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Nexus agents</title>
<style>
:root { color-scheme: light dark; }
body { font: 15px/1.45 system-ui, -apple-system, Segoe UI, sans-serif;
  margin: 0 auto; max-width: 62rem; padding: 2rem 1.25rem 4rem; }
h1 { font-size: 1.35rem; margin: 0 0 .35rem; }
h2 { font-size: 1.05rem; margin: 2rem 0 .5rem; }
p.note { margin: 0 0 1.5rem; opacity: .72; max-width: 46rem; }
table { width: 100%; border-collapse: collapse; }
th, td { text-align: left; padding: .55rem .5rem; vertical-align: top;
  border-bottom: 1px solid rgba(128,128,128,.28); }
th { font-size: .78rem; text-transform: uppercase; letter-spacing: .04em;
  opacity: .68; font-weight: 600; }
td.empty { opacity: .72; padding: 1.2rem .5rem; }
.meta { opacity: .72; font-size: .86rem; }
form { display: inline; }
button { font: inherit; padding: .22rem .55rem; margin: 0 .25rem .25rem 0;
  border: 1px solid rgba(128,128,128,.45); border-radius: .4rem;
  background: transparent; color: inherit; cursor: pointer; }
button:hover { border-color: currentColor; }
.status { font-variant: small-caps; letter-spacing: .03em; }
.halt { color: #b23c17; font-weight: 600; margin: 0 0 .5rem; }
</style>
</head>
<body>
<h1>Nexus agents</h1>
<p class="note">This page is served by Nexus on this PC only. It listens on
127.0.0.1, the link carries a key made at launch, and it stops when Nexus
stops. Nothing on it leaves this computer.</p>
<table>
<thead><tr><th>Agent</th><th>What it does</th><th>Runs</th>
<th>Approval</th><th>Status</th><th></th></tr></thead>
<tbody>$rows</tbody>
</table>
<h2>Halt</h2>
$haltBox
<h2>Halt</h2>
$haltBox
<h2>Usage log</h2>
<p class="meta">$usage</p>
<form method="post" action="$_base/usage">
  <input type="hidden" name="on" value="${store.usageOptIn ? 'no' : 'yes'}">
  <button>${store.usageOptIn ? 'Turn the usage log off and forget it' : 'Turn the usage log on'}</button>
</form>
</body>
</html>''';
  }

  String _row(AgentDefinition agent) {
    final String lastRun = agent.lastRunAt == null
        ? 'never run'
        : 'last run ${_clock(agent.lastRunAt!)}'
              '${agent.lastResult.isEmpty ? '' : ' — ${_fill(agent.lastResult)}'}';
    return '''<tr>
<td><strong>${_fill(agent.name)}</strong></td>
<td>${_fill(agent.goal)}<div class="meta">Tools: ${agent.tools.isEmpty ? 'none' : _fill(agent.tools.join(', '))}</div></td>
<td>${agent.schedule == null ? 'Only when you ask' : _fill(agent.schedule!)}</td>
<td>${_fill(agent.approval.label)}</td>
<td><span class="status">${_fill(agent.status.label)}</span><div class="meta">$lastRun</div></td>
<td>${_buttons(agent)}</td>
</tr>''';
  }

  String _buttons(AgentDefinition agent) {
    final String name = _attr(agent.name);
    String form(String action, String label) =>
        '<form method="post" action="$_base/$action">'
        '<input type="hidden" name="name" value="$name">'
        '<button>$label</button></form>';
    return <String>[
      if (agent.status != AgentStatus.running) form('start', 'Start'),
      if (agent.status == AgentStatus.running) form('pause', 'Pause'),
      if (agent.status != AgentStatus.stopped) form('stop', 'Stop'),
      form('run', 'Run now'),
    ].join();
  }

  static String _clock(DateTime at) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(at.hour)}:${two(at.minute)}';
  }

  /// Text escaped for HTML. Agent names, goals and results are the user's own
  /// words, so none of them is ever written into the page raw.
  static String _fill(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  /// The same escaping for an attribute value.
  static String _attr(String text) => _fill(text).replaceAll("'", '&#39;');
}
