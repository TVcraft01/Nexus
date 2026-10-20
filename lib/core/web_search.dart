// The one way out of this device that the user has to ask for.
//
// Nexus answers from the phone and the PC, and every screen says so. Web search
// is the exception, and it exists because a local model asked about today's
// news will invent it: a lookup that returns nothing is more honest than an
// answer that sounds confident and is three years stale. The switch in the
// composer's `+` is off until the user turns it on, the sheet says what turning
// it on sends, and every failure falls back to the local answer instead of
// failing the question.
//
// DuckDuckGo's HTML endpoint is used rather than a search API because it needs
// no key and no account — the same reason the rest of the app has no server.
// The parser is deliberately small: titles, snippets, links, and nothing that
// pretends to be a page's content.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One result: enough to give a model context and a user a source.
class WebResult {
  const WebResult({
    required this.title,
    required this.snippet,
    required this.url,
  });

  final String title;
  final String snippet;
  final String url;
}

/// Injectable transport, so a test reads a saved page instead of the network.
typedef WebPageFetcher = Future<String?> Function(Uri uri);

/// How long a lookup may take before the question goes on without it. A local
/// answer delayed by eight seconds is worse than a local answer without a
/// search: the search is an addition, never the thing the user is waiting for.
const Duration kWebSearchTimeout = Duration(seconds: 6);

/// Looks [query] up, newest results first, and answers an empty list on any
/// failure — no network, a changed page, a timeout.
Future<List<WebResult>> nexusWebSearch(
  String query, {
  WebPageFetcher? fetch,
  int limit = 3,
}) async {
  final String trimmed = query.trim();
  if (trimmed.isEmpty) return const <WebResult>[];
  final Uri uri = Uri.https('html.duckduckgo.com', '/html/', <String, String>{
    'q': trimmed,
  });
  try {
    final String? html = await (fetch ?? _fetchPage)(uri).timeout(
      kWebSearchTimeout,
    );
    if (html == null || html.isEmpty) return const <WebResult>[];
    return parseDuckDuckGoHtml(html, limit: limit);
  } catch (_) {
    return const <WebResult>[];
  }
}

Future<String?> _fetchPage(Uri uri) async {
  final HttpClient client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 4);
  try {
    final HttpClientRequest request = await client.getUrl(uri);
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Nexus/1.2',
    );
    final HttpClientResponse response = await request.close().timeout(
      const Duration(seconds: 5),
    );
    if (response.statusCode != 200) return null;
    return await response.transform(utf8.decoder).join();
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

final RegExp _resultBody = RegExp(
  r'''class="[^"]*result__body[^"]*"''',
);

final RegExp _anchor = RegExp(
  r'''<a\b([^>]*)>([\s\S]*?)</a>''',
  caseSensitive: false,
);

final RegExp _href = RegExp(
  r'''href\s*=\s*"([^"]*)"''',
  caseSensitive: false,
);

/// Pulls results out of a DuckDuckGo HTML page.
///
/// Split on the result body rather than on the title: a sponsored block has a
/// title too, and the body is what every organic result carries exactly once.
List<WebResult> parseDuckDuckGoHtml(String html, {int limit = 3}) {
  final List<WebResult> out = <WebResult>[];
  final List<int> starts = <int>[
    for (final RegExpMatch match in _resultBody.allMatches(html)) match.start,
  ];
  for (int i = 0; i < starts.length && out.length < limit; i++) {
    final int from = starts[i];
    final int to = i + 1 < starts.length ? starts[i + 1] : html.length;
    final String chunk = html.substring(from, to);
    String title = '';
    String url = '';
    String snippet = '';
    for (final RegExpMatch anchor in _anchor.allMatches(chunk)) {
      final String attributes = anchor.group(1) ?? '';
      final String text = _cleanText(anchor.group(2) ?? '');
      if (attributes.contains('result__a') && title.isEmpty) {
        title = text;
        url = _resultUrl(_href.firstMatch(attributes)?.group(1) ?? '');
      } else if (attributes.contains('result__snippet') && snippet.isEmpty) {
        snippet = text;
      }
    }
    if (title.isEmpty || url.isEmpty) continue;
    out.add(WebResult(title: title, snippet: snippet, url: url));
  }
  return out;
}

/// The real destination, not DuckDuckGo's redirect wrapper.
String _resultUrl(String href) {
  final String decoded = _decodeEntities(href);
  if (decoded.isEmpty) return '';
  final Uri? uri = Uri.tryParse(decoded);
  if (uri == null) return '';
  final String? target = uri.queryParameters['uddg'];
  if (target != null && target.isNotEmpty) return target;
  if (uri.hasScheme) return uri.toString();
  return 'https:$decoded';
}

/// Visible text: tags gone, entities decoded, runs of whitespace collapsed.
String _cleanText(String raw) => _decodeEntities(
  raw.replaceAll(RegExp(r'<[^>]+>'), ' '),
).replaceAll(RegExp(r'\s+'), ' ').trim();

String _decodeEntities(String raw) => raw
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#x27;', "'")
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&nbsp;', ' ')
    .replaceAllMapped(
      RegExp(r'&#x([0-9a-fA-F]+);'),
      (Match m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
    )
    .replaceAllMapped(
      RegExp(r'&#(\d+);'),
      (Match m) => String.fromCharCode(int.parse(m.group(1)!)),
    );

/// The block handed to the model with the question.
///
/// Says where it came from and when, because a snippet has a date the model
/// does not: "as of today" is a claim it cannot check, and the search results
/// are the only part of the prompt that is actually current.
String webContextBlock(List<WebResult> results) {
  if (results.isEmpty) return '';
  final StringBuffer buffer = StringBuffer(
    'The user allows web search. These are live results; use them for anything '
    'that changes, and name the source when you quote it.\n',
  );
  for (final WebResult result in results) {
    buffer.writeln('- ${result.title}: ${result.snippet} (${result.url})');
  }
  return buffer.toString();
}
