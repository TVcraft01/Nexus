import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/app_defaults.dart';
import 'package:nexus/core/device_actions.dart';
import 'package:nexus/core/profile.dart';
import 'package:nexus/core/live.dart';
import 'package:nexus/core/phone_actions.dart';
import 'package:nexus/ui/device_executor.dart';

/// Captures every backend call so tests assert routing without a widget tree.
class _FakeDeviceBackend implements DeviceActionBackend {
  final calls = <(String action, Map<String, dynamic> args)>[];
  final chooserCalls = <(String url, String title)>[];
  bool chooserResult = false;
  bool previewOk = true;
  (double, double)? location;
  List<Map<String, dynamic>> calendarEvents = const [];
  @override
  Future<ActionResult> run(String action, Map<String, dynamic> args) async {
    calls.add((action, args));
    if (action == AgentActions.calendarRead) {
      return ActionResult(true, 'ok', data: {'events': calendarEvents});
    }
    if (action == 'mediaPreview') {
      return previewOk
          ? const ActionResult(true, 'Playing.')
          : const ActionResult(false, 'Preview failed');
    }
    return ActionResult(true, 'ran $action');
  }

  @override
  Future<(double, double)?> currentLocation() async => location;

  @override
  Future<bool> openLinkChooser(String url, String title) async {
    chooserCalls.add((url, title));
    return chooserResult;
  }
}

/// Records the place/coordinates each weather fetch was asked for.
class _FakeWeatherFetcher {
  final calls = <(String place, String kind, String? coordinates)>[];
  String? reply = 'In Paris it\'s 18°C.';

  Future<String?> call(String place, String kind, {String? coordinates}) async {
    calls.add((place, kind, coordinates));
    return reply;
  }
}

/// Records the coordinates each area lookup was asked for.
class _FakeAreaDetector {
  final calls = <String?>[];
  String? reply = 'Montpellier';

  Future<String?> call({String? coordinates}) async {
    calls.add(coordinates);
    return reply;
  }
}

/// Records the queries of a fake Deezer search.
class _FakeMusicSearcher {
  final queries = <String>[];
  MusicHit? reply;

  Future<MusicHit?> call(String query) async {
    queries.add(query);
    return reply;
  }
}

/// Records the (from, to) pairs of a fake rate service.
class _FakeRateFetcher {
  final pairs = <(String, String)>[];
  double? reply;

  Future<double?> call(String from, String to) async {
    pairs.add((from, to));
    return reply;
  }
}

/// Records the zones of a fake time service.
class _FakeZoneTimeFetcher {
  final zones = <String>[];
  (String, String)? reply;

  Future<(String, String)?> call(String zone) async {
    zones.add(zone);
    return reply;
  }
}

class _FakePhoneBackend implements PhoneActionBackend {
  final dials = <String?>[]; // every number passed to callContact
  final names = <String>[];
  PhoneCallOutcome reply =
      const PhoneCallOutcome(placed: true, message: 'Calling.');
  @override
  Future<PhoneCallOutcome> callContact(String name, {String? number}) async {
    names.add(name);
    dials.add(number);
    return reply;
  }

  @override
  Future<PhoneCallOutcome> videoCall(String name, String? app) async =>
      PhoneCallOutcome(
        placed: false,
        launched: app != null && app.isNotEmpty,
        message: app == null ? 'No app.' : 'Opened $app.',
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeDeviceBackend device;
  late _FakePhoneBackend phone;
  late DeviceExecutor executor;

  setUp(() {
    // The executor's platform branches mirror Android (method channels);
    // force android so routing is deterministic on every host.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    device = _FakeDeviceBackend();
    phone = _FakePhoneBackend();
    executor = DeviceExecutor(deviceBackend: device, phoneBackend: phone);
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  AgentRequest req(String action, [Map<String, dynamic> args = const {}]) =>
      AgentRequest(requestId: 'r', action: action, target: 'self', arguments: args);

  test('a taught number reaches the phone backend on call', () async {
    final out = await executor.run(req(
      AgentActions.callPlace,
      {'contact': 'mom', 'number': '0612345678'},
    ));
    expect(out.ok, isTrue);
    expect(phone.names, ['mom']);
    expect(phone.dials, ['0612345678']);
  });

  test('a name-only call resolves natively (no number forwarded)', () async {
    await executor.run(req(AgentActions.callPlace, {'contact': 'dad'}));
    expect(phone.names, ['dad']);
    expect(phone.dials, [null]);
  });

  test('video calls carry the app, never the dial path', () async {
    final out = await executor.run(req(
      AgentActions.callPlace,
      {'contact': 'mom', 'mode': 'video', 'app': 'whatsapp'},
    ));
    // No plain callContact dial — the video branch answers separately.
    expect(phone.names, isEmpty);
    expect(out.ok, isTrue);
  });

  test('text forwards contact, number and body to the device backend', () async {
    await executor.run(req(
      AgentActions.messageSend,
      {'contact': 'mom', 'number': '0612345678', 'body': 'hi'},
    ));
    expect(device.calls, hasLength(1));
    final (action, args) = device.calls.single;
    expect(action, AgentActions.messageSend);
    expect(args['contact'], 'mom');
    expect(args['number'], '0612345678');
    expect(args['body'], 'hi');
  });

  test('media controls map to the media control action', () async {
    await executor.run(req(AgentActions.mediaPlay));
    expect(device.calls.single.$1, AgentActions.mediaPlay);
  });

  test('unknown actions answer honestly, never silently', () async {
    final out = await executor.run(req('comm.nonexistent'));
    expect(out.ok, isFalse);
    expect(device.calls, isEmpty);
  });

  test('email forwards contact and body to the device backend', () async {
    await executor.run(req(
      AgentActions.emailSend,
      {'contact': 'mom', 'body': 'hi'},
    ));
    final (action, args) = device.calls.single;
    expect(action, AgentActions.emailSend);
    expect(args['contact'], 'mom');
    expect(args['body'], 'hi');
  });

  test('a volume level reaches the backend as a set mode', () async {
    await executor.run(req(
      AgentActions.volumeSet,
      {'mode': 'set', 'level': 50},
    ));
    final (action, args) = device.calls.single;
    expect(action, AgentActions.volumeSet);
    expect(args['mode'], 'set');
    expect(args['level'], 50);
  });

  test('a named song searches the catalog and opens the top hit', () async {
    final searcher = _FakeMusicSearcher()
      ..reply = const MusicHit('Hotline Bling', 'Drake', 'https://deezer.page.link/x');
    executor = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
      musicSearcher: searcher.call,
    );
    final out = await executor.run(req(
      AgentActions.musicSearch,
      {'query': 'hotline bling'},
    ));
    expect(searcher.queries, ['hotline bling']);
    // The hit was found honestly; opening the link is a browser/app task
    // that failed in this headless test — the message says exactly that.
    expect(out.message, contains('Hotline Bling'));
    expect(out.message, contains('Drake'));
  });

  test('an unfindable song answers honestly, never a fake play', () async {
    final searcher = _FakeMusicSearcher()..reply = null;
    executor = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
      musicSearcher: searcher.call,
    );
    final out = await executor.run(req(
      AgentActions.musicSearch,
      {'query': 'qqqqqq'},
    ));
    expect(out.ok, isFalse);
    expect(out.message, contains('couldn\'t find'));
    expect(device.calls, isEmpty); // never a silent media key press
  });

  test('music opens through the app chooser, never a silent default', () async {
    final searcher = _FakeMusicSearcher()
      ..reply = const MusicHit('Hotline Bling', 'Drake', 'https://deezer.page.link/x');
    device.chooserResult = true;
    executor = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
      musicSearcher: searcher.call,
    );
    final out = await executor.run(req(
      AgentActions.musicSearch,
      {'query': 'hotline bling'},
    ));
    expect(out.ok, isTrue);
    expect(device.chooserCalls, [('https://deezer.page.link/x', 'Open in')]);
    expect(out.message, contains('opening it'));
  });

  test('play X on spotify deep-links into Spotify, never a Deezer search',
      () async {
    final searcher = _FakeMusicSearcher();
    device.chooserResult = true;
    executor = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
      musicSearcher: searcher.call,
    );
    final out = await executor.run(req(
      AgentActions.musicSearch,
      {'query': 'hotline bling', 'app': 'spotify'},
    ));
    expect(out.ok, isTrue);
    expect(searcher.queries, isEmpty, reason: 'never hits the Deezer API');
    expect(device.chooserCalls,
        [('https://open.spotify.com/search/hotline%20bling', 'Open in')]);
    expect(out.message, 'Playing "hotline bling" in Spotify.');
  });

  test('generic play on a player opens it with an empty search', () async {
    device.chooserResult = true;
    executor = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
      musicSearcher: _FakeMusicSearcher().call,
    );
    final out = await executor.run(req(
      AgentActions.musicSearch,
      {'query': '', 'app': 'deezer'},
    ));
    expect(out.ok, isTrue);
    expect(device.chooserCalls,
        [('https://www.deezer.com/search/', 'Open in')]);
    expect(out.message, 'Playing in Deezer.');
  });

  test('play X on a player answers honestly when it cannot open', () async {
    // chooserResult stays false: no app/browser took the deep link.
    executor = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
      musicSearcher: _FakeMusicSearcher().call,
    );
    final out = await executor.run(req(
      AgentActions.musicSearch,
      {'query': 'hotline bling', 'app': 'spotify'},
    ));
    expect(out.ok, isFalse);
    expect(out.message, contains('Spotify'));
    expect(device.calls, isEmpty, reason: 'never a silent media key press');
  });

  test('an unknown player answers honestly, never a literal search', () async {
    final searcher = _FakeMusicSearcher();
    executor = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
      musicSearcher: searcher.call,
    );
    final out = await executor.run(req(
      AgentActions.musicSearch,
      {'query': 'hotline bling', 'app': 'netflix'},
    ));
    expect(out.ok, isFalse);
    expect(out.message, contains('netflix'));
    expect(searcher.queries, isEmpty);
  });

  test('navigate home with waze deep-links into Waze', () async {
    device.chooserResult = true;
    executor = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
      musicSearcher: _FakeMusicSearcher().call,
    );
    final out = await executor.run(req(
      AgentActions.navOpen,
      {'query': 'home', 'app': 'waze'},
    ));
    expect(out.ok, isTrue);
    expect(device.chooserCalls, [('https://waze.com/ul?q=home', 'Open in')]);
    expect(out.message, 'Directions to "home" in Waze.');
    expect(device.calls, isEmpty, reason: 'no geo: chooser on the app path');
  });

  test('navigate with an unknown app answers honestly', () async {
    executor = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
      musicSearcher: _FakeMusicSearcher().call,
    );
    final out = await executor.run(req(
      AgentActions.navOpen,
      {'query': 'home', 'app': 'netflix'},
    ));
    expect(out.ok, isFalse);
    expect(out.message, contains('netflix'));
    expect(device.chooserCalls, isEmpty);
  });

  test('add dinner to google calendar deep-links into its compose form',
      () async {
    device.chooserResult = true;
    executor = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
      musicSearcher: _FakeMusicSearcher().call,
    );
    final out = await executor.run(req(
      AgentActions.calendarAdd,
      {'title': 'dinner', 'app': 'google'},
    ));
    expect(out.ok, isTrue);
    expect(device.chooserCalls, [
      ('https://calendar.google.com/calendar/render?action=TEMPLATE&text=dinner',
          'Open in'),
    ]);
    expect(out.message, 'Adding "dinner" to Google Calendar.');
    expect(device.calls, isEmpty, reason: 'no ACTION_INSERT on the app path');
  });

  test('calendar add with an unknown app answers honestly', () async {
    executor = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
      musicSearcher: _FakeMusicSearcher().call,
    );
    final out = await executor.run(req(
      AgentActions.calendarAdd,
      {'title': 'dinner', 'app': 'notion'},
    ));
    expect(out.ok, isFalse);
    expect(out.message, contains('notion'));
    expect(device.chooserCalls, isEmpty);
  });

  test('music with a free preview plays in-app, no chooser needed', () async {
    final searcher = _FakeMusicSearcher()
      ..reply = const MusicHit(
        'Hotline Bling',
        'Drake',
        'https://deezer.page.link/x',
        preview: 'https://cdn-preview.example/stream.mp3',
      );
    executor = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
      musicSearcher: searcher.call,
    );
    final out = await executor.run(req(
      AgentActions.musicSearch,
      {'query': 'hotline bling'},
    ));
    expect(out.ok, isTrue);
    expect(device.chooserCalls, isEmpty); // Nexus plays it itself
    expect(device.calls.length, 1);
    expect(device.calls.first.$1, 'mediaPreview');
    expect(device.calls.first.$2, {
      'action': 'play',
      'url': 'https://cdn-preview.example/stream.mp3',
    });
    expect(out.message, contains('preview'));
    expect(out.message, contains('Hotline Bling'));
  });

  test('music preview failure falls back to the app chooser', () async {
    final searcher = _FakeMusicSearcher()
      ..reply = const MusicHit(
        'Hotline Bling',
        'Drake',
        'https://deezer.page.link/x',
        preview: 'https://cdn-preview.example/stream.mp3',
      );
    device.chooserResult = true;
    device.previewOk = false;
    executor = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
      musicSearcher: searcher.call,
    );
    final out = await executor.run(req(
      AgentActions.musicSearch,
      {'query': 'hotline bling'},
    ));
    expect(out.ok, isTrue);
    expect(device.chooserCalls, [('https://deezer.page.link/x', 'Open in')]);
  });

  test('"pause music" pauses the in-app preview first, then media keys', () async {
    executor = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
    );
    final out = await executor.run(req(AgentActions.mediaPause));
    expect(out.ok, isTrue);
    expect(device.calls.first.$1, 'mediaPreview');
    expect(device.calls.first.$2, {'action': 'pause'});
  });

  test('calendar read formats the next events with times', () async {
    final lunch = DateTime(2026, 9, 8, 12, 30).millisecondsSinceEpoch;
    device.calendarEvents = [
      {'title': 'Lunch with mom', 'start': lunch, 'location': 'Café'},
      {'title': 'Dentist', 'start': lunch + 2 * 3600 * 1000, 'location': ''},
    ];
    executor = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
    );
    final out = await executor.run(req(
      AgentActions.calendarRead,
      {'when': 'today'},
    ));
    expect(out.ok, isTrue);
    expect(device.calls.length, 1);
    expect(device.calls.first.$1, AgentActions.calendarRead);
    expect(device.calls.first.$2, {'when': 'today'});
    expect(out.message, contains('Today on your calendar'));
    expect(out.message, contains('Lunch with mom'));
    expect(out.message, contains('12:30'));
    expect(out.message, contains('Café'));
  });

  test('calendar read answers honestly when nothing is scheduled', () async {
    executor = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
    );
    final out = await executor.run(req(
      AgentActions.calendarRead,
      {'when': 'tomorrow'},
    ));
    expect(out.ok, isTrue);
    expect(out.message, contains('Nothing on your calendar tomorrow'));
  });

  test('unresolved calls carry the candidate names for "who did you mean?"', () async {
    phone.reply = const PhoneCallOutcome(
      placed: false,
      candidates: ['Alex', 'Alicia'],
      message: 'No contact named "alx" on this device. Did you mean "Alex"?',
    );
    final out = await executor.run(req(AgentActions.callPlace, {'contact': 'alx'}));
    expect(out.ok, isFalse);
    expect(out.candidates, ['Alex', 'Alicia']);
    expect(out.message, contains('Did you mean'));
  });

  test('currency converts with today\'s fetched rate, honestly', () async {
    final rates = _FakeRateFetcher()..reply = 0.92;
    executor = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
      rateFetcher: rates.call,
    );
    final out = await executor.run(req(
      AgentActions.currencyGet,
      {'value': 100.0, 'from': 'usd', 'to': 'eur'},
    ));
    expect(rates.pairs, [('usd', 'eur')]);
    expect(out.ok, isTrue);
    expect(out.message, '100.0 USD = 92.00 EUR (ECB rate today).');
    final offline = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
      rateFetcher: (f, t) async => null,
    );
    final fail = await offline.run(req(
      AgentActions.currencyGet,
      {'value': 1.0, 'from': 'usd', 'to': 'eur'},
    ));
    expect(fail.ok, isFalse);
    expect(fail.message, contains('rate'));
  });

  test('timezone answers from the live service for a curated city', () async {
    final zones = _FakeZoneTimeFetcher()..reply = ('15:42', 'JST');
    executor = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
      zoneTimeFetcher: zones.call,
    );
    final out = await executor.run(req(
      AgentActions.timezoneGet,
      {'place': 'tokyo'},
    ));
    expect(zones.zones, ['Asia/Tokyo']);
    expect(out.ok, isTrue);
    expect(out.message, 'In tokyo it\'s 15:42 (JST).');
    // Unmapped cities never guess a zone.
    final unknown = await executor.run(req(
      AgentActions.timezoneGet,
      {'place': 'atlantis'},
    ));
    expect(unknown.ok, isFalse);
    expect(unknown.message, contains('time zone'));
  });

  group('a platform gap is explained, never dismissed', () {
    // macOS has no native Nexus integration at all, which makes it the honest
    // probe for the class: every action Nexus cannot do there has to name the
    // action and the systems that can, rather than blame "this platform".
    tearDown(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
    });

    const phoneOrDesktop = <String, Map<String, dynamic>>{
      AgentActions.appOpen: {'query': 'safari'},
      AgentActions.appClose: {'query': 'safari'},
      AgentActions.screenshot: {},
      AgentActions.batteryGet: {},
      AgentActions.brightnessSet: {'mode': 'up'},
      AgentActions.flashlightToggle: {},
      AgentActions.wifiToggle: {},
      AgentActions.bluetoothToggle: {},
      AgentActions.lockScreen: {},
      AgentActions.mediaPlay: {},
      AgentActions.volumeSet: {'mode': 'up'},
      AgentActions.alarmSet: {'hour': 7, 'minute': 0},
      AgentActions.calendarRead: {'when': 'today'},
    };

    for (final entry in phoneOrDesktop.entries) {
      test('${entry.key} says what and where', () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        final out = await executor.run(req(entry.key, entry.value));
        expect(out.ok, isFalse, reason: entry.key);
        expect(out.message, contains('macOS'), reason: entry.key);
        expect(
          out.message,
          contains('Nexus does that on'),
          reason: '${entry.key} does not say where it does work',
        );
        // Nothing here is a missing detail — the request was complete, the
        // system simply cannot run it, so it must not be reported as a
        // question waiting on the user either.
        expect(out.needsDetail, isFalse, reason: entry.key);
      });
    }
  });

  test('a desktop calendar read explains itself and fakes nothing', () async {
    // The defect this guards: "what's on my calendar?" fell through to the
    // backend's default branch and answered "That action is not available on
    // this device." — a dead end that named neither the calendar nor a system
    // that has one. It must also never answer "nothing today" for a calendar
    // it never read: that would tell the user their day is clear when it isn't.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;

    final out = await executor.run(req(
      AgentActions.calendarRead,
      {'when': 'today'},
    ));

    expect(out.ok, isFalse);
    expect(out.message, "I can't read your calendar on Linux — "
        'Nexus does that on your phone.');
    expect(out.message, isNot(contains('Nothing on your calendar')));
    expect(out.needsDetail, isFalse, reason: 'nothing is missing from the ask');
    // And the read never happened: no backend call, no empty result to report.
    expect(device.calls, isEmpty);
  });

  test('adding a calendar event goes through the device backend on Android',
      () async {
    final out = await executor.run(req(
      AgentActions.calendarAdd,
      {'title': 'lunch with mom'},
    ));
    expect(out.ok, isTrue);
    expect(device.calls.single.$1, AgentActions.calendarAdd);
    expect(device.calls.single.$2['title'], 'lunch with mom');
  });

  test('weather with a city fetches that city, never the location', () async {
    final fetcher = _FakeWeatherFetcher();
    executor = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
      weatherFetcher: fetcher.call,
    );
    final out = await executor.run(req(
      AgentActions.weatherGet,
      {'place': 'Paris', 'kind': 'now'},
    ));
    expect(out.ok, isTrue);
    expect(out.message, 'In Paris it\'s 18°C.');
    expect(fetcher.calls, [('Paris', 'now', null)]);
  });

  test('weather without a city uses the device location when available',
      () async {
    device.location = (48.8566, 2.3522);
    final fetcher = _FakeWeatherFetcher();
    executor = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
      weatherFetcher: fetcher.call,
    );
    final out = await executor.run(req(
      AgentActions.weatherGet,
      {'place': '', 'kind': 'now'},
    ));
    expect(out.ok, isTrue);
    expect(fetcher.calls, [('', 'now', '48.8566,2.3522')]);
  });

  test('weather without a city and without location falls back to IP auto',
      () async {
    final fetcher = _FakeWeatherFetcher();
    executor = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
      weatherFetcher: fetcher.call,
    );
    final out = await executor.run(req(
      AgentActions.weatherGet,
      {'place': '', 'kind': 'now'},
    ));
    expect(out.ok, isTrue);
    expect(fetcher.calls, [('', 'now', null)]);
  });

  test('"where am i" names the area from the device fix', () async {
    device.location = (43.61, 3.87);
    final detector = _FakeAreaDetector();
    executor = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
      areaDetector: detector.call,
    );
    final out = await executor.run(req(AgentActions.locationGet));
    expect(out.ok, isTrue);
    expect(out.message, 'You\'re in Montpellier.');
    expect(detector.calls, ['43.61,3.87']);
  });

  test('"where am i" falls back to the network area without a fix', () async {
    final detector = _FakeAreaDetector();
    executor = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
      areaDetector: detector.call,
    );
    final out = await executor.run(req(AgentActions.locationGet));
    expect(out.ok, isTrue);
    expect(out.message, contains('You appear to be near Montpellier'));
    expect(detector.calls, [null]);
  });

  test('"where am i" fails honestly when nothing resolves', () async {
    final detector = _FakeAreaDetector()..reply = null;
    executor = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
      areaDetector: detector.call,
    );
    final out = await executor.run(req(AgentActions.locationGet));
    expect(out.ok, isFalse);
    expect(out.message, contains('couldn\'t determine your location'));
  });

  test('weather reports a fetch failure honestly, never a fake forecast',
      () async {
    final fetcher = _FakeWeatherFetcher()..reply = null;
    executor = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
      weatherFetcher: fetcher.call,
    );
    final out = await executor.run(req(
      AgentActions.weatherGet,
      {'place': 'Paris', 'kind': 'now'},
    ));
    expect(out.ok, isFalse);
    expect(out.message, contains('couldn\'t reach the weather service'));
  });

  test('a remembered music default routes bare play to that app', () async {
    final store = MemoryAppDefaultsStore();
    await store.write(AppDefaultDomain.music, 'spotify');
    device.chooserResult = true;
    executor = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
      musicSearcher: _FakeMusicSearcher().call,
      defaultsStore: store,
    );
    final out = await executor.run(req(AgentActions.mediaPlay));
    expect(out.ok, isTrue);
    expect(out.message, 'Playing in Spotify.');
    expect(device.chooserCalls,
        [('https://open.spotify.com/search/', 'Open in')]);
  });

  test('a remembered music default routes named-song searches to that app',
      () async {
    final store = MemoryAppDefaultsStore();
    await store.write(AppDefaultDomain.music, 'deezer');
    device.chooserResult = true;
    executor = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
      musicSearcher: _FakeMusicSearcher().call,
      defaultsStore: store,
    );
    final out = await executor.run(req(
      AgentActions.musicSearch,
      {'query': 'hotline bling'},
    ));
    expect(out.ok, isTrue);
    expect(out.message, 'Playing "hotline bling" in Deezer.');
    expect(device.chooserCalls,
        [('https://www.deezer.com/search/hotline%20bling', 'Open in')]);
  });

  test('an explicitly named app still overrides the remembered default',
      () async {
    final store = MemoryAppDefaultsStore();
    await store.write(AppDefaultDomain.music, 'deezer');
    device.chooserResult = true;
    executor = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
      musicSearcher: _FakeMusicSearcher().call,
      defaultsStore: store,
    );
    final out = await executor.run(req(
      AgentActions.musicSearch,
      {'query': 'hotline bling', 'app': 'spotify'},
    ));
    expect(out.ok, isTrue);
    expect(out.message, 'Playing "hotline bling" in Spotify.');
    expect(device.chooserCalls,
        [('https://open.spotify.com/search/hotline%20bling', 'Open in')]);
  });

  test('navigate home honors the remembered nav default', () async {
    final store = MemoryAppDefaultsStore();
    await store.write(AppDefaultDomain.navigation, 'waze');
    device.chooserResult = true;
    executor = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
      defaultsStore: store,
    );
    final out = await executor.run(req(
      AgentActions.navOpen,
      {'query': 'home'},
    ));
    expect(out.ok, isTrue);
    expect(out.message, 'Directions to "home" in Waze.');
    expect(device.chooserCalls, [('https://waze.com/ul?q=home', 'Open in')]);
  });

  test('add dinner to my calendar honors the remembered calendar default',
      () async {
    final store = MemoryAppDefaultsStore();
    await store.write(AppDefaultDomain.calendar, 'google');
    device.chooserResult = true;
    executor = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
      defaultsStore: store,
    );
    final out = await executor.run(req(
      AgentActions.calendarAdd,
      {'title': 'dinner'},
    ));
    expect(out.ok, isTrue);
    expect(out.message, 'Adding "dinner" to Google Calendar.');
    expect(
      device.chooserCalls,
      [
        (
          'https://calendar.google.com/calendar/render?action=TEMPLATE&text=dinner',
          'Open in',
        ),
      ],
    );
  });

  test('nav default answers with the directions confirmation', () async {
    final store = MemoryAppDefaultsStore();
    executor = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
      defaultsStore: store,
    );
    final out = await executor.run(req(
      AgentActions.appDefault,
      {'verb': 'set', 'domain': 'navigation', 'app': 'waze', 'name': 'Waze'},
    ));
    expect(out.ok, isTrue);
    expect(out.message, 'I\'ll use Waze for directions from now on.');
    expect(await store.read(AppDefaultDomain.navigation), 'waze');
  });

  test('call me X persists the name and greets back; what is my name reads it',
      () async {
    final profile = MemoryProfileStore();
    executor = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
      profileStore: profile,
    );
    final set = await executor.run(req(
      AgentActions.profileSet,
      {'kind': 'user', 'name': 'Sam'},
    ));
    expect(set.ok, isTrue);
    expect(set.message, 'Nice to meet you, Sam.');
    expect((await profile.read()).userName, 'Sam');
    final get = await executor.run(req(AgentActions.profileGet));
    expect(get.ok, isTrue);
    expect(get.message, 'Your name is Sam.');
  });

  test('what is my name answers honestly before any name is set', () async {
    executor = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
      profileStore: MemoryProfileStore(),
    );
    final get = await executor.run(req(AgentActions.profileGet));
    expect(get.ok, isTrue);
    expect(get.message, contains('I don\'t know your name yet'));
    expect(get.message, contains('call me Sam'));
  });

  test('call yourself X renames the assistant', () async {
    final profile = MemoryProfileStore();
    executor = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
      profileStore: profile,
    );
    final out = await executor.run(req(
      AgentActions.profileSet,
      {'kind': 'assistant', 'name': 'Sophie'},
    ));
    expect(out.ok, isTrue);
    expect(out.message, 'Okay — call me Sophie from now on.');
    expect((await profile.read()).assistantName, 'Sophie');
  });

  test('always use X persists, clears, and restores old behavior', () async {
    final store = MemoryAppDefaultsStore();
    device.chooserResult = true;
    executor = DeviceExecutor(
      deviceBackend: device,
      phoneBackend: phone,
      musicSearcher: _FakeMusicSearcher().call,
      defaultsStore: store,
    );
    // Set through the real dispatch surface, exactly as the interpreter emits.
    final set = await executor.run(req(
      AgentActions.appDefault,
      {'verb': 'set', 'domain': 'music', 'app': 'deezer', 'name': 'Deezer'},
    ));
    expect(set.ok, isTrue);
    expect(set.message, 'Using Deezer from now on.');
    expect(await store.read(AppDefaultDomain.music), 'deezer');
    // Bare phrases now route there…
    final bare = await executor.run(req(AgentActions.mediaPlay));
    expect(bare.message, 'Playing in Deezer.');
    // …and clearing restores plain media-control behavior.
    final clear = await executor.run(req(
      AgentActions.appDefault,
      {'verb': 'clear', 'domain': 'music', 'app': 'deezer', 'name': 'Deezer'},
    ));
    expect(clear.ok, isTrue);
    expect(clear.message, 'Stopping use of Deezer.');
    expect(await store.read(AppDefaultDomain.music), isNull);
    device.chooserCalls.clear();
    final after = await executor.run(req(AgentActions.mediaPlay));
    expect(after.ok, isTrue);
    expect(device.chooserCalls, isEmpty);
    expect(
      device.calls.any((c) => c.$1 == 'media.play' && c.$2['mode'] == 'play'),
      isTrue,
      reason: 'bare play without a default goes back to the media key',
    );
  });

  group('a missing detail is a question, not a failure', () {
    // Every place the executor stops to ask for something the user has to
    // supply must say so, because the assistant reports the flag it returns:
    // without it, "Who should I call?" reached the chip under the verdict
    // "Unavailable" and turned the Nexus core's error state on.
    const asking = <String, Map<String, dynamic>>{
      AgentActions.webSearch: {},
      AgentActions.openUrl: {},
      AgentActions.appOpen: {},
      AgentActions.appClose: {},
      AgentActions.calendarAdd: {},
      AgentActions.shoppingListAdd: {},
      AgentActions.navOpen: {},
      AgentActions.callPlace: {},
      AgentActions.messageSend: {},
      AgentActions.emailSend: {},
      AgentActions.timerSet: {'seconds': 0},
      AgentActions.musicSearch: {},
    };

    for (final entry in asking.entries) {
      test('${entry.key} asks for what it lacks', () async {
        final out = await executor.run(req(entry.key, entry.value));
        expect(out.ok, isFalse, reason: entry.key);
        expect(out.needsDetail, isTrue, reason: entry.key);
        expect(out.message, contains('?'), reason: entry.key);
      });
    }

    test('an unparseable duration is a question too', () async {
      // "set a timer for soon" cannot be parsed: the user has to say how
      // long, in the wording the executor asks in.
      final out = await executor.run(
        req(AgentActions.timerSet, {'seconds': 'soon'}),
      );
      expect(out.needsDetail, isTrue);
      expect(out.message.toLowerCase(), contains('how long'));
    });

    test('a video call with nobody named is a question', () async {
      final out = await executor.run(
        req(AgentActions.callPlace, {'mode': 'video'}),
      );
      expect(out.needsDetail, isTrue);
      expect(out.message, 'Who should I video call?');
    });

    test('a genuine failure does not claim to be a question', () async {
      // The counterweight: the flag must not have spread to real failures,
      // or the word "Question" would start covering for broken features.
      executor = DeviceExecutor(
        deviceBackend: device,
        phoneBackend: phone,
        musicSearcher: (_FakeMusicSearcher()..reply = null).call,
      );
      final out = await executor.run(
        req(AgentActions.musicSearch, {'query': 'qqqqqq'}),
      );
      expect(out.ok, isFalse);
      expect(out.needsDetail, isFalse);
      expect(out.message, isNot(contains('?')));
    });
  });
}

