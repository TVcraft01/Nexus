// Place reminders, driven the way the mission demands: the switch first,
// the map second, the fence third.
//
// A fresh install has every optional capability off; flipping the location
// switch without permission leaves it off with an honest sentence; the
// set_location_reminder tool refuses while the switch is off WITHOUT
// phoning any map; an empty Nominatim answer stores nothing; and a fired
// fence marks its reminder spent. The widget tests at the bottom walk the
// real Settings row, denied and granted.
import 'dart:io';

import 'package:flutter/cupertino.dart' show CupertinoSwitch;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_tools.dart';
import 'package:nexus/core/capabilities.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/location_access.dart';
import 'package:nexus/core/location_reminders.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/ui/settings_view.dart';
import 'package:nexus/ui/theme.dart';

/// A map that answers on script: the lookup the tests control.
class _FakeLookup implements PlaceLookup {
  int calls = 0;
  String? lastQuery;
  double? lastNearLat;
  double? lastNearLng;
  PlaceMatch? answer;

  @override
  Future<PlaceMatch?> search(
    String query, {
    double? nearLat,
    double? nearLng,
  }) async {
    calls++;
    lastQuery = query;
    lastNearLat = nearLat;
    lastNearLng = nearLng;
    return answer;
  }
}

const _match = PlaceMatch(
  displayName: 'Tesco Superstore, London',
  lat: 51.5,
  lng: -0.1,
);

/// Registers through a scripted map and a recording channel mock.
/// Returns what the model would be told, plus what the platform heard.
Future<({String answer, List<MethodCall> calls, List<LocationReminder> kept})>
_register({
  required bool allowed,
  PlaceMatch? answer = _match,
  String what = 'buy milk',
  String where = 'grocery store',
}) async {
  final lookup = _FakeLookup()..answer = answer;
  final channel = const MethodChannel('dev.nexus.nexus/location');
  final calls = <MethodCall>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  final kept = <LocationReminder>[];
  final setup = LocationReminderSetup(
    lookup: lookup,
    currentFix: () async => (51.4, -0.12),
    geofences: LocationGeofences(channel: channel),
  );
  final said = await setup.register(
    allowed: allowed,
    what: what,
    where: where,
    known: kept,
    onPersist: kept.add,
  );
  return (answer: said, calls: calls, kept: kept);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('fresh install: every optional capability is off', () async {
    final tmp = await Directory.systemTemp.createTemp('loc_fresh');
    addTearDown(() => tmp.delete(recursive: true));
    final store = NexusStore(explicitPath: '${tmp.path}/s.json');
    expect(store.locationReminders, isFalse);
    expect(store.clipboardSync, isFalse);
    expect(store.voiceInput, isFalse);
    for (final (capability, info) in CapabilityInfo.all()) {
      if (info.alwaysOn) {
        expect(info.read(store), isTrue, reason: '$capability stays on');
      } else {
        expect(info.read(store), isFalse, reason: '$capability starts off');
      }
    }
  });

  test('the rows disclose the price before the toggle can move', () {
    final rows = {
      for (final (capability, info) in CapabilityInfo.all())
        capability: info,
    };
    expect(
      rows[Capability.locationReminders]!.description,
      contains('one'),
    );
    expect(
      rows[Capability.locationReminders]!.description,
      contains('lookup'),
    );
    expect(
      rows[Capability.locationReminders]!.needs,
      contains('Always'),
    );
    expect(
      rows[Capability.localModel]!.description,
      contains('470MB'),
    );
    expect(rows[Capability.meshPairing]!.alwaysOn, isTrue);
    expect(rows[Capability.localModel]!.alwaysOn, isTrue);
  });

  test('Nominatim parses one result and biases with the fix', () async {
    Uri? seen;
    final lookup = NominatimLookup(
      fetch: (url) async {
        seen = url;
        return '[{"lat": "51.5", "lon": "-0.12", '
            '"display_name": "Tesco Superstore, London"}]';
      },
    );
    final match = await lookup.search(
      'grocery store',
      nearLat: 51.4,
      nearLng: -0.1,
    );
    expect(match, isNotNull);
    expect(match!.displayName, 'Tesco Superstore, London');
    expect(match.lat, closeTo(51.5, 0.0001));
    expect(match.lng, closeTo(-0.12, 0.0001));
    expect(seen!.host, 'nominatim.openstreetmap.org');
    expect(seen!.queryParameters['q'], 'grocery store');
    expect(seen!.queryParameters['format'], 'jsonv2');
    expect(seen!.queryParameters['limit'], '1');
    expect(seen!.queryParameters['lat'], '51.4');
    expect(seen!.queryParameters['lon'], '-0.1');
  });

  test('Nominatim returning nothing resolves to nothing', () async {
    final empty = NominatimLookup(fetch: (_) async => '[]');
    expect(await empty.search('nowhere lane'), isNull);
    final torn = NominatimLookup(fetch: (_) async => 'not json');
    expect(await torn.search('grocery store'), isNull);
    final failed = NominatimLookup(fetch: (_) async => '');
    expect(await failed.search('grocery store'), isNull);
  });

  test('allowed: one lookup, one stored fence, one honest confirmation',
      () async {
    final (:answer, :calls, :kept) = await _register(allowed: true);
    expect(kept, hasLength(1));
    expect(kept.single.what, 'buy milk');
    expect(kept.single.placeName, 'Tesco Superstore, London');
    expect(kept.single.fired, isFalse);
    expect(kept.single.radiusM, LocationReminder.defaultRadiusM);
    final syncs = [
      for (final call in calls)
        if (call.method == 'syncLocationGeofences') call,
    ];
    expect(syncs, hasLength(1));
    final fences =
        (syncs.single.arguments as Map)['fences'] as List;
    expect(fences, hasLength(1));
    expect(fences.single['lat'], closeTo(51.5, 0.0001));
    expect(fences.single['what'], 'buy milk');
    expect(answer, contains('Tesco Superstore, London'));
    expect(answer, contains('OpenStreetMap once'));
    expect(answer, contains('nothing else'));
  });

  test('denied: the model is told it is off, and no lookup happens',
      () async {
    final lookup = _FakeLookup()..answer = _match;
    final kept = <LocationReminder>[];
    final setup = LocationReminderSetup(
      lookup: lookup,
      currentFix: () async => (51.4, -0.12),
    );
    final said = await setup.register(
      allowed: false,
      what: 'buy milk',
      where: 'grocery store',
      known: kept,
      onPersist: kept.add,
    );
    expect(said, contains('off'));
    expect(said, contains('Capabilities'));
    expect(lookup.calls, 0, reason: 'an off switch phones no map');
    expect(kept, isEmpty);
  });

  test('the runner gates too: off answers, on delegates', () async {
    var delegated = 0;
    final off = LocalToolRunner(
      fetch: (name, from) async => 'unused',
      locationRemindersAllowed: () => false,
      remindAtPlace: (what, where) async {
        delegated++;
        return 'fenced';
      },
    );
    final refusal = await off.run(
      const ToolCall(NexusTool.setLocationReminder, {
        'what': 'buy milk',
        'where': 'grocery store',
      }),
    );
    expect(refusal, contains('off'));
    expect(delegated, 0);

    final on = LocalToolRunner(
      fetch: (name, from) async => 'unused',
      locationRemindersAllowed: () => true,
      remindAtPlace: (what, where) async {
        delegated++;
        return 'fenced for $what at $where';
      },
    );
    expect(
      await on.run(
        const ToolCall(NexusTool.setLocationReminder, {
          'what': 'buy milk',
          'where': 'grocery store',
        }),
      ),
      'fenced for buy milk at grocery store',
    );
    expect(delegated, 1);
  });

  test('a time ask routed at the place tool is refused', () {
    final call = ToolCall(NexusTool.setLocationReminder, {
      'what': 'take milk',
      'when': '18:00',
    });
    expect(
      toolRefusal(call, 'remind me to take milk at 6pm'),
      'the ask names no place to remind at',
    );
    expect(
      toolRefusal(
        ToolCall(NexusTool.setLocationReminder, {
          'what': 'buy milk',
          'where': 'grocery store',
        }),
        'remind me to buy milk when I get to the grocery store',
      ),
      isNull,
    );
  });

  test('no match: honest message, nothing stored, nothing fenced', () async {
    final (:answer, :calls, :kept) = await _register(
      allowed: true,
      answer: null,
    );
    expect(answer, contains('could not find'));
    expect(answer, contains('nothing was stored'));
    expect(kept, isEmpty);
    expect(
      calls.where((call) => call.method == 'syncLocationGeofences'),
      isEmpty,
    );
  });

  test('a fired fence marks its reminder spent, in memory and in store',
      () async {
    final reminder = LocationReminder(
      id: 'p-1',
      what: 'buy milk',
      whereQuery: 'grocery store',
      placeName: 'Tesco Superstore, London',
      lat: 51.5,
      lng: -0.1,
    );
    final spent = reminder.markFired();
    expect(spent.fired, isTrue);
    expect(spent.what, reminder.what);
    expect(reminder.fired, isFalse, reason: 'the mark is a copy, not a edit');

    final tmp = await Directory.systemTemp.createTemp('loc_fired');
    addTearDown(() => tmp.delete(recursive: true));
    final path = '${tmp.path}/s.json';
    final store = NexusStore(explicitPath: path)
      ..addPlaceReminder(reminder.toJson());
    expect(store.markPlaceReminderFired('p-1'), isTrue);
    expect(store.markPlaceReminderFired('p-nope'), isFalse);
    await store.save();

    final reloaded = NexusStore(explicitPath: path);
    await reloaded.load();
    final lines = reloaded.placeReminders
        .map(LocationReminder.fromJson)
        .whereType<LocationReminder>()
        .toList();
    expect(lines, hasLength(1));
    expect(lines.single.fired, isTrue);
  });

  test('a torn place line refuses itself, never a fence nowhere', () {
    expect(LocationReminder.fromJson(null), isNull);
    expect(LocationReminder.fromJson({'id': 'p-1'}), isNull);
    expect(
      LocationReminder.fromJson({
        'id': 'p-1',
        'what': 'buy milk',
        'whereQuery': 'store',
        'placeName': 'Tesco',
        // no coordinates: no centre, no fence.
      }),
      isNull,
    );
  });

  test('spent fences leave the armed set', () async {
    final channel = const MethodChannel('dev.nexus.nexus/location');
    final calls = <MethodCall>[];
    final synced = <List>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'syncLocationGeofences') {
            synced.add(
              (call.arguments as Map)['fences'] as List,
            );
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final fences = LocationGeofences(channel: channel);
    final pending = LocationReminder(
      id: 'p-pending',
      what: 'buy milk',
      whereQuery: 'store',
      placeName: 'Tesco',
      lat: 51.5,
      lng: -0.1,
    );
    await fences.sync([pending]);
    await fences.sync([pending.markFired()]);
    // One arming, then a removal: a spent fence is dropped, never
    // re-armed — the same cancel-semantics as the exact alarms.
    expect(synced, hasLength(1));
    expect(synced.single.single['id'], 'p-pending');
    final removals = [
      for (final call in calls)
        if (call.method == 'removeLocationGeofences') call,
    ];
    expect(removals, hasLength(1));
    expect(
      (removals.single.arguments as Map)['ids'],
      ['p-pending'],
    );
  });

  test('the place tool has its worked example in the prompt', () {
    const example =
        'For example, the user asks "remind me to buy milk when I get to '
        'the grocery store" — reply exactly:\n'
        'TOOL:set_location_reminder {"what": "buy milk", '
        '"where": "grocery store"}';
    for (final devices in const [
      <String>[],
      ['Rehearsal PC'],
    ]) {
      expect(
        toolSystemPrompt('You are Nexus.', pairedDevices: devices),
        contains(example),
      );
    }
  });

  group('the Settings row', () {
    // Boots a mesh the way the settings tests do: the store's save chain
    // is created where it is constructed, on the far side of runAsync.
    Future<({NexusStore store, MeshService mesh})> boot(
      WidgetTester tester,
      String path,
    ) async {
      late NexusStore store;
      late MeshService mesh;
      await tester.runAsync(() async {
        store = NexusStore(explicitPath: path);
        store.autoUpdate = false; // a shell test must not reach the network
        store.broadcastDiscovery = false; // never touch the network
        await store.save();
        mesh = MeshService(
          identity: DeviceInfo(
            id: 'loc-row-device',
            name: 'Location PC',
            platform: 'linux',
          ),
          store: store,
        );
      });
      return (store: store, mesh: mesh);
    }

    Future<void> pumpSettings(WidgetTester tester, MeshService mesh) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildNexusTheme(),
          home: Scaffold(body: SettingsView(mesh: mesh)),
        ),
      );
      await tester.pump();
    }

    Future<CupertinoSwitch> locationSwitch(WidgetTester tester) async {
      final name = find.text('Location reminders');
      await tester.scrollUntilVisible(
        name,
        120,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
      final row = find.ancestor(of: name, matching: find.byType(Row)).first;
      return tester.widget<CupertinoSwitch>(
        find.descendant(of: row, matching: find.byType(CupertinoSwitch)),
      );
    }

    testWidgets('denied permission: the switch stays off and says why', (
      tester,
    ) async {
      // Sync fs calls: the widget zone is fake-async, and awaiting real
      // IO there never completes — the settings tests do the same.
      final tmp = Directory.systemTemp.createTempSync('loc_denied');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final (:store, :mesh) = await boot(tester, '${tmp.path}/s.json');
      try {
        ReminderLocation.debugRequestOverride = () async =>
            const LocationPermissionResult(
              granted: false,
              message: 'Location reminders need \u2018Always\u2019 location '
                  'permission. Time reminders still work.',
            );
        addTearDown(() => ReminderLocation.debugRequestOverride = null);
        await pumpSettings(tester, mesh);
        await tester.tap(find.text('Location reminders'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 500));

        expect((await locationSwitch(tester)).value, isFalse);
        expect(store.locationReminders, isFalse);
        expect(
          find.textContaining('Time reminders still work'),
          findsOneWidget,
        );
      } finally {
        await tester.runAsync(mesh.stop);
      }
    });

    testWidgets('granted permission: the switch turns on and stays on', (
      tester,
    ) async {
      final tmp = Directory.systemTemp.createTempSync('loc_granted');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final (:store, :mesh) = await boot(tester, '${tmp.path}/s.json');
      try {
        ReminderLocation.debugRequestOverride = () async =>
            const LocationPermissionResult(granted: true);
        addTearDown(() => ReminderLocation.debugRequestOverride = null);
        await pumpSettings(tester, mesh);
        await tester.tap(find.text('Location reminders'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 500));

        expect((await locationSwitch(tester)).value, isTrue);
        expect(store.locationReminders, isTrue);
      } finally {
        await tester.runAsync(mesh.stop);
      }
    });
  });
}
