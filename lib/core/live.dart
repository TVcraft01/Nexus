// Live lookups for the assistant — small, free, keyless HTTP services, all
// with injectable seams so the whole module is testable without a network:
//
//  - music search: Deezer's public search API (no key, rate-limited)
//  - currency: frankfurter.app, ECB reference rates (no key)
//  - timezone time: worldtimeapi.org (no key)
//
// Every fetch returns null on any failure — the caller answers honestly
// instead of inventing data.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One music hit: the top Deezer track for a query.
class MusicHit {
  final String title;
  final String artist;
  final String url;
  const MusicHit(this.title, this.artist, this.url);
}

/// Injectable seam: search music and return the top hit, or null.
typedef MusicSearcher = Future<MusicHit?> Function(String query);

/// Injectable seam: today's rate from [from] to [to], or null.
typedef RateFetcher = Future<double?> Function(String from, String to);

/// Injectable seam: (local HH:mm, abbreviation) for an IANA zone, or null.
typedef ZoneTimeFetcher = Future<(String time, String abbrev)?> Function(
  String zone,
);

/// Searches Deezer's public catalog for [query] and returns the top track.
Future<MusicHit?> searchMusic(String query) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final uri = Uri.parse(
      'https://api.deezer.com/search?q=${Uri.encodeQueryComponent(query)}&limit=1',
    );
    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close().timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return null;
    final body = await response.transform(utf8.decoder).join();
    return parseDeezerHit(body);
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// Parses a Deezer `search` payload into the top hit, or null.
MusicHit? parseDeezerHit(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  final data = (decoded['data'] as List? ?? const []).whereType<Map>().toList();
  if (data.isEmpty) return null;
  final track = data.first;
  final title = track['title']?.toString();
  final artist = ((track['artist'] as Map?)?? {})['name']?.toString();
  final url = track['link']?.toString();
  if (title == null || title.isEmpty || url == null || url.isEmpty) {
    return null;
  }
  return MusicHit(title, artist ?? 'Unknown artist', url);
}

/// Fetches today's ECB reference rate from [from] to [to] (frankfurter.app).
Future<double?> fetchRate(String from, String to) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final uri = Uri.parse(
      'https://api.frankfurter.app/latest?from='
      '${Uri.encodeQueryComponent(from.toUpperCase())}'
      '&to=${Uri.encodeQueryComponent(to.toUpperCase())}',
    );
    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close().timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return null;
    final body = await response.transform(utf8.decoder).join();
    return parseRate(body, to);
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// Extracts the rate for [to] from a frankfurter `latest` payload, or null.
double? parseRate(String body, String to) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  final rates = decoded['rates'];
  if (rates is! Map) return null;
  final raw = rates[to.toUpperCase()];
  if (raw is num) return raw.toDouble();
  return double.tryParse(raw?.toString() ?? '');
}

/// Fetches the current local time for an IANA zone (worldtimeapi.org).
Future<(String, String)?> fetchZoneTime(String zone) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final uri = Uri.parse('https://worldtimeapi.org/api/timezone/$zone');
    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close().timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return null;
    final body = await response.transform(utf8.decoder).join();
    return parseZoneTime(body);
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// Extracts (HH:mm, abbreviation) from a worldtimeapi payload, or null.
(String, String)? parseZoneTime(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  final raw = decoded['datetime']?.toString();
  final abbrev = decoded['abbreviation']?.toString() ?? '';
  if (raw == null || raw.length < 16) return null;
  final time = raw.substring(11, 16); // "2026-09-06T15:42:00+09:00" → "15:42"
  if (!RegExp(r'^\d{2}:\d{2}$').hasMatch(time)) return null;
  return (time, abbrev);
}