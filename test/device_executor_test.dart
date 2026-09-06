import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/device_actions.dart';
import 'package:nexus/core/phone_actions.dart';
import 'package:nexus/ui/device_executor.dart';

/// Captures every backend call so tests assert routing without a widget tree.
class _FakeDeviceBackend implements DeviceActionBackend {
  final calls = <(String action, Map<String, dynamic> args)>[];
  @override
  Future<ActionResult> run(String action, Map<String, dynamic> args) async {
    calls.add((action, args));
    return ActionResult(true, 'ran $action');
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

  test('targeted play answers honestly — no fake library search', () async {
    final out = await executor.run(req(
      AgentActions.mediaPlay,
      {'query': 'my playlist'},
    ));
    expect(out.ok, isFalse); // honest: cannot search the library
    expect(out.message, contains('search'));
    expect(device.calls, isEmpty); // never a silent media key press
  });
}

