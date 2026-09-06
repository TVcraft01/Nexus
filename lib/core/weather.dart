// Weather lookup for the assistant. One small, honest dependency: wttr.in
// (free, no key, JSON via ?format=j1). The HTTP client is injectable so the
// whole module is testable without a network — the app's real fetches use
// dart:io's HttpClient through the same seam.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One formatted weather line, e.g. "In Paris it's 18°C, Partly cloudy,
/// feels like 17°C." or the rain forecast variant. Null when the lookup
/// failed or the payload did not parse.
typedef WeatherFetcher = Future<String?> Function(
  String place,
  String kind, {
  String? coordinates,
});

/// Resolves an area name for a device fix or the network location.
/// Returns null when wttr.in couldn't be reached or named anything.
typedef AreaDetector = Future<String?> Function({String? coordinates});

/// The default fetcher: GETs wttr.in and formats the JSON reply. With no
/// [place] and no [coordinates] it hits wttr.in's IP-detected location
/// (`auto`) — the fallback when a device has no location fix.
Future<String?> fetchWeather(
  String place,
  String kind, {
  String? coordinates,
}) async {
  // wttr.in accepts "lat,lon" and "auto" as locations.
  final location =
      coordinates ?? (place.isNotEmpty ? Uri.encodeComponent(place) : 'auto');
  final decoded = await _fetchWttr(location);
  if (decoded == null) return null;
  return formatWttr(jsonEncode(decoded), place: place, kind: kind);
}

/// Names the area for [coordinates] (device fix), or the IP-detected area
/// when [coordinates] is null — the "where am I" answer source.
Future<String?> detectArea({String? coordinates}) async {
  final decoded = await _fetchWttr(coordinates ?? 'auto');
  if (decoded == null) return null;
  return areaFromWttr(jsonEncode(decoded));
}

/// Extracts the resolved area name from a wttr.in `format=j1` payload, or
/// null when the payload names nothing.
String? areaFromWttr(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  final areas = (decoded['nearest_area'] as List? ?? const [])
      .whereType<Map>()
      .toList();
  final name = ((areas.firstOrNull?['areaName'] as List? ?? const [])
          .whereType<Map>()
          .toList()
          .firstOrNull?['value'])
      ?.toString();
  if (name == null || name.isEmpty) return null;
  return name;
}

/// GETs wttr.in `format=j1` and returns the decoded JSON, or null on any
/// network or parse failure.
Future<Map<String, dynamic>?> _fetchWttr(String location) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final uri = Uri.parse('https://wttr.in/$location?format=j1');
    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close().timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return null;
    final body = await response.transform(utf8.decoder).join();
    final decoded = jsonDecode(body);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// Parses a wttr.in `format=j1` payload into one honest line.
String? formatWttr(String body, {required String place, String kind = 'now'}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  final current = (decoded['current_condition'] as List? ?? const [])
      .whereType<Map>()
      .toList();
  if (current.isEmpty) return null;
  final c = current.first;
  // wttr.in sends temps as strings ("18") — accept both shapes.
  int? asInt(Object? v) => int.tryParse(v?.toString() ?? '');
  final tempC = asInt(c['temp_C']);
  final feels = asInt(c['FeelsLikeC']);
  final desc = ((c['weatherDesc'] as List? ?? const [])
          .whereType<Map>()
          .toList()
          .firstOrNull?['value'])
      ?.toString();
  if (tempC == null) return null;

  // When the caller had no city (location/IP fetch), name the area wttr.in
  // actually resolved — the answer names a real place, never a guess.
  var label = place.isNotEmpty ? place : '';
  if (label.isEmpty) {
    final areas = (decoded['nearest_area'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    final name = ((areas.firstOrNull?['areaName'] as List? ?? const [])
            .whereType<Map>()
            .toList()
            .firstOrNull?['value'])
        ?.toString();
    if (name != null && name.isNotEmpty) label = name;
  }
  if (label.isEmpty) label = 'Your area';

  if (kind == 'rain') {
    // Hourly chance-of-rain is the best "will it rain today" signal wttr.in
    // exposes; report the peak, not a made-up average.
    final hours = (decoded['weather'] as List? ?? const [])
        .whereType<Map>()
        .expand((d) => (d['hourly'] as List? ?? const []).whereType<Map>())
        .toList();
    // wttr.in sends chanceofrain as a string ("60") — accept both shapes.
    int chanceOf(Object? v) =>
        int.tryParse(v?.toString() ?? '') ?? (v is num ? v.toInt() : 0);
    final peak = hours
        .map((h) => chanceOf(h['chanceofrain']))
        .fold<int>(0, (a, b) => b > a ? b : a);
    return peak > 0
        ? 'In $label, there is up to a $peak% chance of rain today.'
        : 'In $label, no rain is forecast today.';
  }

  final degrees = '$tempC°C';
  final withFeels = feels != null && feels != tempC
      ? ' (feels like $feels°C)'
      : '';
  final withDesc = desc != null && desc.isNotEmpty ? ', $desc' : '';
  return 'In $label it\'s $degrees$withFeels$withDesc.';
}