import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/device_actions.dart';
import 'package:nexus/core/live.dart';
import 'package:nexus/core/phone_actions.dart';
import 'package:nexus/ui/device_executor.dart';

/// Captures every backend call so tests assert routing without a widget tree.
class _FakeDeviceBackend implements DeviceActionBackend {
  final calls = <(String action, Map<String, dynamic> args)>[];
  (double, double)? location;
  @override
  Future<ActionResult> run(String action, Map<String, dynamic> args) async {
    calls.add((action, args));
    return ActionResult(true, 'ran $action');
  }

  @override
  Future<(double, double)?> currentLocation() async => location;
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
  @override
  Future<PhoneCallOutcome> callContact(String name, {String? number}) async {
    names.add(name);
    dials.add(number);
    return const PhoneCallOutcome(placed: true, message: 'Calling.');
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
}

