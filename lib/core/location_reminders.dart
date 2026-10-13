// Place reminders: \"remind me to take milk at the store\" fires on arrival.
//
// One file on purpose: the model, the one network call this feature ever
// makes, the bridge that arms the native fence, and the registrar that ties
// them together behind the capability gate. Pure Dart with injected seams;
// the edges (store persistence, the platform fence) are callbacks and a
// channel the view wires, so everything here is testable without widgets
// or a phone.
//
// The privacy contract, stated once so every layer says the same thing:
// resolving a new place sends its NAME (plus the current fix, when known,
// to pick the nearest match) to nominatim.openstreetmap.org exactly once,
// and caches the coordinates on-device. A repeat visit to a known place
// costs no lookup. When the capability is off, no lookup ever happens.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show MethodChannel;

/// One reminder tied to a place instead of a time. A fired one stays with
/// [fired] set — spent, never re-fired — so the store tells the truth
/// about what already rang, exactly like a time reminder.
class LocationReminder {
  /// The fence radius around every place, in metres. A store is bigger
  /// than a GPS wobble; 200m fires at arrival, not across the street.
  static const double defaultRadiusM = 200;

  final String id;
  final String what;
  final String whereQuery;
  final String placeName;
  final double lat;
  final double lng;
  final double radiusM;
  final bool fired;

  const LocationReminder({
    required this.id,
    required this.what,
    required this.whereQuery,
    required this.placeName,
    required this.lat,
    required this.lng,
    this.radiusM = defaultRadiusM,
    this.fired = false,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'what': what,
    'whereQuery': whereQuery,
    'placeName': placeName,
    'lat': lat,
    'lng': lng,
    'radiusM': radiusM,
    'fired': fired,
  };

  /// A torn or foreign line never breaks a place reminder. Whatever is
  /// missing — coordinates, names — refuses the whole line: a fence with
  /// no centre is worse than no fence.
  static LocationReminder? fromJson(Map<String, dynamic>? data) {
    if (data == null) return null;
    try {
      final id = data['id']?.toString();
      final what = data['what']?.toString();
      final whereQuery = data['whereQuery']?.toString();
      final placeName = data['placeName']?.toString();
      final lat = (data['lat'] as num?)?.toDouble();
      final lng = (data['lng'] as num?)?.toDouble();
      if (id == null ||
          id.isEmpty ||
          what == null ||
          what.isEmpty ||
          whereQuery == null ||
          placeName == null ||
          lat == null ||
          lng == null) {
        return null;
      }
      return LocationReminder(
        id: id,
        what: what,
        whereQuery: whereQuery,
        placeName: placeName,
        lat: lat,
        lng: lng,
        radiusM:
            (data['radiusM'] as num?)?.toDouble() ?? defaultRadiusM,
        fired: data['fired'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  /// The spent copy: same fence, rung. The store holds the mark, the
  /// native side drops the fence — neither fires it again.
  LocationReminder markFired() => LocationReminder(
    id: id,
    what: what,
    whereQuery: whereQuery,
    placeName: placeName,
    lat: lat,
    lng: lng,
    radiusM: radiusM,
    fired: true,
  );
}

/// One map match: the name to say back and the centre to fence.
class PlaceMatch {
  const PlaceMatch({
    required this.displayName,
    required this.lat,
    required this.lng,
  });

  final String displayName;
  final double lat;
  final double lng;
}

/// Resolves a place name to coordinates. One call per new place; a
/// repeat visit to a known place never reaches the network.
abstract class PlaceLookup {
  Future<PlaceMatch?> search(
    String query, {
    double? nearLat,
    double? nearLng,
  });
}

/// The place-name lookup, against OpenStreetMap's Nominatim.
///
/// Exactly what leaves the device, per new place, once: the query string
/// (\"grocery store\"), plus the current fix when known so the nearest
/// match wins. Nothing else — no identity, no history, no what. The
/// answer (coordinates, display name) is cached on-device with the
/// reminder; the next \"milk at the store\" costs no lookup.
class NominatimLookup implements PlaceLookup {
  NominatimLookup({Future<String> Function(Uri url)? fetch})
    : _fetch = fetch ?? _get;

  final Future<String> Function(Uri url) _fetch;

  @override
  Future<PlaceMatch?> search(
    String query, {
    double? nearLat,
    double? nearLng,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return null;
    final params = <String, String>{
      'q': trimmed,
      'format': 'jsonv2',
      'limit': '1',
    };
    // A known fix biases the match to the nearby store, not one across
    // the country with the same name.
    if (nearLat != null && nearLng != null) {
      params['lat'] = nearLat.toString();
      params['lon'] = nearLng.toString();
    }
    final url = Uri.https('nominatim.openstreetmap.org', '/search', params);
    final body = await _fetch(url);
    if (body.isEmpty) return null;
    try {
      final decoded = jsonDecode(body);
      if (decoded is! List || decoded.isEmpty) return null;
      final first = decoded.first;
      if (first is! Map) return null;
      final lat = double.tryParse(first['lat']?.toString() ?? '');
      final lng = double.tryParse(first['lon']?.toString() ?? '');
      final name = first['display_name']?.toString();
      if (lat == null || lng == null || name == null || name.isEmpty) {
        return null;
      }
      return PlaceMatch(displayName: name, lat: lat, lng: lng);
    } catch (_) {
      return null;
    }
  }

  /// The real fetch: one GET with the User-Agent Nominatim's usage
  /// policy asks for. Anything but a 200 is an empty answer — the
  /// registrar says \"couldn't find it\", never a status code.
  static Future<String> _get(Uri url) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(url);
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'Nexus/1.0 (location reminders; one lookup per new place)',
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) return '';
      return await response.transform(utf8.decoder).join();
    } catch (_) {
      return '';
    } finally {
      client.close();
    }
  }
}

/// The device's current fix, best-effort and silent off Android — null
/// means \"unknown\", and the lookup then matches without a bias instead
/// of failing. A test hands the registrar its own fix.
typedef CurrentFix = Future<(double, double)?> Function();

/// Reads the fix through the `dev.nexus.nexus/location` channel (see
/// LocationReminders.kt): {ok, lat, lon}, or silence when there is no
/// bridge, no permission, or no fix yet.
Future<(double, double)?> deviceFix({MethodChannel? channel}) async {
  try {
    final raw = await (channel ??
            const MethodChannel('dev.nexus.nexus/location'))
        .invokeMapMethod<String, dynamic>('currentLocation');
    final lat = (raw?['lat'] as num?)?.toDouble();
    final lng = (raw?['lon'] as num?)?.toDouble();
    if (raw?['ok'] == true && lat != null && lng != null) {
      return (lat, lng);
    }
    return null;
  } catch (_) {
    return null;
  }
}

/// Arms the native fence behind every pending place reminder, through the
/// `dev.nexus.nexus/location` channel (see LocationReminders.kt). Mirrors
/// [ReminderAlarms]: sync is idempotent, each call guarded, silence off
/// Android — the in-app engine has no timer for places, so without a
/// bridge a place reminder is stored but cannot fire, and says so.
class LocationGeofences {
  LocationGeofences({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('dev.nexus.nexus/location');

  final MethodChannel _channel;

  /// Fence ids synced to the platform. Sync is idempotent: fencing the
  /// same id replaces its fence, and ids that left the pending set are
  /// removed so a deleted reminder cannot ring.
  final Set<String> _synced = {};

  /// One stable notification id per reminder, shared by the fence post
  /// and the in-app post — computed in Dart so both sides agree without
  /// a round trip.
  static int notificationId(String id) => id.hashCode & 0x7fffffff;

  /// Hands every unfired reminder to the platform and removes fences
  /// whose reminders are gone or spent.
  Future<void> sync(Iterable<LocationReminder> reminders) async {
    final pending = <String, LocationReminder>{};
    for (final reminder in reminders) {
      if (!reminder.fired) pending[reminder.id] = reminder;
    }
    final stale = _synced.where((id) => !pending.containsKey(id)).toList();
    if (stale.isNotEmpty) {
      _synced.removeAll(stale);
      await _call('removeLocationGeofences', {
        'ids': stale,
      });
    }
    if (pending.isEmpty) return;
    _synced.addAll(pending.keys);
    await _call('syncLocationGeofences', {
      'fences': [
        for (final reminder in pending.values)
          {
            'id': reminder.id,
            'notificationId': notificationId(reminder.id),
            'lat': reminder.lat,
            'lng': reminder.lng,
            'radiusM': reminder.radiusM,
            'what': reminder.what,
            'placeName': reminder.placeName,
          },
      ],
    });
  }

  /// Fence ids the platform fired while Dart was not looking. Reading
  /// clears the native set — each fire is collected exactly once, then
  /// the store marks it spent.
  Future<List<String>> takeFiredIds() async {
    try {
      final raw = await _channel.invokeMethod<dynamic>(
        'takeFiredLocationIds',
      );
      if (raw is List) {
        return [for (final id in raw) id.toString()];
      }
      return const [];
    } catch (_) {
      return const [];
    }
  }

  /// Forgets everything without touching the platform: the owner was
  /// disposed (tests, logout) and no fence state may linger past it.
  void reset() => _synced.clear();

  Future<void> _call(String method, Map<String, dynamic> args) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } catch (_) {
      // No bridge, no fence — the reminder stays stored, unfired.
    }
  }
}

/// Sets a place reminder the way the tool does: gated, looked up once,
/// fenced. What comes back is the observation handed to the model — and
/// through it, the sentence the user reads.
///
/// The dependencies are seams. [lookup] resolves names (a test hands a
/// fake; the product uses [NominatimLookup]), [currentFix] biases the
/// match (a test hands a fix; the product reads the device), and
/// [geofences] arms the fence (a test hands a channel mock; the product
/// uses the platform).
class LocationReminderSetup {
  LocationReminderSetup({
    PlaceLookup? lookup,
    CurrentFix? currentFix,
    LocationGeofences? geofences,
  }) : _lookup = lookup ?? NominatimLookup(),
       _currentFix = currentFix ?? deviceFix,
       _geofences = geofences ?? LocationGeofences();

  final PlaceLookup _lookup;
  final CurrentFix _currentFix;
  final LocationGeofences _geofences;

  /// Registers \"remind me to [what] at [where]\" and answers what
  /// happened, in one sentence.
  ///
  /// [allowed] is the capability switch. Off means off: the model is
  /// told the user has not turned location reminders on, and NO lookup
  /// happens — an off switch that still phones a map is not off.
  /// [onPersist] stores the reminder on this device; [known] are the
  /// reminders already stored, fenced with the new one.
  Future<String> register({
    required bool allowed,
    required String what,
    required String where,
    required void Function(LocationReminder reminder) onPersist,
    required Iterable<LocationReminder> known,
  }) async {
    final task = what.trim();
    if (task.isEmpty) return 'What should I remind you about?';
    final place = where.trim();
    if (place.isEmpty) {
      return 'Which place should remind you to $task? Name somewhere — '
          'a store, a street, home or work.';
    }
    if (!allowed) {
      return 'Location reminders are off — the user has not turned them '
          'on in Settings › Capabilities. I did not look anything up; '
          'ask them to flip the switch first.';
    }
    final fix = await _currentFix();
    final match = await _lookup.search(
      place,
      nearLat: fix?.$1,
      nearLng: fix?.$2,
    );
    if (match == null) {
      // Nothing stored: a reminder fenced nowhere would never fire, and
      // a guess at the wrong store is worse than a question.
      return 'I could not find \u201c$place\u201d on the map, so nothing '
          'was stored. Try a nearby landmark or a fuller address.';
    }
    final reminder = LocationReminder(
      id: 'p-${DateTime.now().microsecondsSinceEpoch}',
      what: task,
      whereQuery: place,
      placeName: match.displayName,
      lat: match.lat,
      lng: match.lng,
    );
    onPersist(reminder);
    // The persisted copy may already sit in [known] (the view's working
    // list is the store's mirror): fence by id, so the new fence is
    // armed exactly once either way.
    await _geofences.sync([
      ...{for (final other in known) other.id: other, reminder.id: reminder}.values,
    ]);
    return 'I will remind you to $task when you arrive at '
        '${match.displayName}. Finding it sent \u201c$place\u201d to '
        'OpenStreetMap once to get its coordinates; nothing else ever '
        'leaves your phone for this.';
  }
}
