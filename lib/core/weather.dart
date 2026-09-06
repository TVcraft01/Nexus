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
typedef WeatherFetcher = Future<String?> Function(String place, String kind);

/// The default fetcher: GETs wttr.in and formats the JSON reply.
Future<String?> fetchWeather(String place, String kind) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final uri = Uri.parse(
      'https://wttr.in/${Uri.encodeComponent(place)}?format=j1',
    );
    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close().timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return null;
    final body = await response.transform(utf8.decoder).join();
    return formatWttr(body, place: place, kind: kind);
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
        ? 'In $place, there is up to a $peak% chance of rain today.'
        : 'In $place, no rain is forecast today.';
  }

  final degrees = '$tempC°C';
  final withFeels = feels != null && feels != tempC
      ? ' (feels like $feels°C)'
      : '';
  final withDesc = desc != null && desc.isNotEmpty ? ', $desc' : '';
  return 'In $place it\'s $degrees$withFeels$withDesc.';
}