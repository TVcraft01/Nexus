// The three honest answers the seam makes possible, driven through the real
// service: what devices Nexus can use, where a device kind actually resolves,
// and why the last request could not be done — with the four reasons kept
// apart from one another.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/capability.dart';
import 'package:nexus/core/command_service.dart';

CommandService _service({
  List<AgentDeviceSnapshot> devices = const [],
  Set<String> locallyExecutable = const {},
}) => CommandService(
  devices: () => devices,
  local: AgentDeviceSnapshot(
    id: 'd1',
    name: 'Test Desk',
    online: true,
    capabilities: defaultCapabilitiesFor('linux'),
    platform: 'linux',
  ),
  locallyExecutable: locallyExecutable,
);

AgentDeviceSnapshot _phone({bool online = true, String name = 'Pixel 8'}) =>
    AgentDeviceSnapshot(
      id: 'p1',
      name: name,
      online: online,
      capabilities: defaultCapabilitiesFor('android'),
      platform: 'android',
    );

String _text(AgentDispatchResult result) {
  final dispatch = result.dispatch;
  if (dispatch is AgentMessage) return dispatch.text;
  return result.message;
}

AgentDispatchResult _ask(CommandService service, String input) =>
    service.execute(input);

void main() {
  group('"what devices can you use" answers from the registry', () {
    test('it is the same capability lookup as "show my devices"', () {
      // Same registry, different question — so the same action id carries it,
      // and the answer is built from the resource map instead of the widget.
      final service = _service(devices: [_phone()]);
      final result = _ask(service, 'what devices can you use');
      expect(result.status, AgentResultStatus.succeeded);
      expect(result.dispatch, isA<AgentMessage>());
      expect(result.dispatch, isNot(isA<AgentDeviceList>()));
    });

    test('with nothing paired it lists this device and invents no others', () {
      final result = _ask(_service(), 'what devices can you use');
      final text = _text(result);
      expect(text, contains('Test Desk — this device'));
      expect(text, contains('listed but not wired up here'));
      expect(text, isNot(contains('assumed from its platform')));
    });

    test('with no device at all it says so rather than listing nothing', () {
      final service = CommandService(devices: () => const []);
      expect(
        _text(_ask(service, 'what devices can you use')),
        contains('I don\'t know about any devices yet'),
      );
    });

    test('each device is listed with its state', () {
      final result = _ask(
        _service(devices: [_phone(), _phone(online: false, name: 'Old Phone')]),
        'what can my devices do',
      );
      final text = _text(result);
      expect(text, contains('Test Desk'));
      expect(text, contains('this device'));
      expect(text, contains('Pixel 8'));
      expect(text, contains('online'));
      expect(text, contains('Old Phone'));
      expect(text, contains('offline'));
    });

    test('what this device really runs is split from what it merely lists',
        () {
      final result = _ask(
        _service(devices: [_phone()], locallyExecutable: const {'search.web'}),
        'what devices can you use',
      );
      final text = _text(result);
      expect(text, contains('runs now: Search'));
      expect(
        text,
        contains('listed but not wired up here'),
        reason: 'a platform capability this device has not proven is not a fact',
      );
    });

    test('a peer is never presented as proof of what it can do', () {
      final result = _ask(_service(devices: [_phone()]), 'what devices can you use');
      final text = _text(result);
      expect(text, contains('assumed from its platform'));
      expect(
        text,
        contains('has never told me what it can really do'),
        reason: 'no peer announces capabilities in this release',
      );
    });

    test('the plain device list is untouched — it still lists devices', () {
      final result = _ask(_service(devices: [_phone()]), 'show my devices');
      expect(result.dispatch, isA<AgentDeviceList>());
      expect((result.dispatch! as AgentDeviceList).devices.length, 1);
    });
  });

  group('"where is my phone" resolves the kind, not a name', () {
    test('a phone called something else is still found', () {
      // The device is named "Pixel 8" and its name contains no kind word at
      // all, so the only way to find it is the platform it reported.
      final result = _ask(_service(devices: [_phone()]), 'where is my phone');
      final text = _text(result);
      expect(text, contains('Pixel 8'));
      expect(
        text,
        isNot(contains('I don\'t have a device matching')),
        reason: 'the kind resolved against the registry rather than the name',
      );
    });

    test('a kind nobody has still says so, and names what is paired', () {
      final result = _ask(_service(devices: [_phone()]), 'where is my laptop');
      final text = _text(result);
      expect(text, contains('I don\'t have a device matching "laptop"'));
      expect(text, contains('Pixel 8'));
    });

    test('a name still wins over a kind', () {
      final service = _service(devices: [
        _phone(name: 'Work laptop'),
        _phone(),
      ]);
      final text = _text(_ask(service, 'where is my laptop'));
      expect(text, contains('Work laptop'));
      expect(text, isNot(contains('Pixel 8')));
    });
  });

  group('"why can\'t you do this" names the real reason', () {
    test('with nothing failed it says there is nothing to explain', () {
      final result = _ask(_service(), 'why can\'t you do this');
      expect(_text(result), contains('Nothing has failed'));
    });

    test('a sentence Nexus never understood is not blamed on a device', () {
      final service = _service(devices: [_phone()]);
      _ask(service, 'teleport me to mars');
      final text = _text(_ask(service, 'why can\'t you do this'));
      expect(text, contains('I didn\'t understand "teleport me to mars"'));
      expect(text, contains('What I said'));
      expect(text, isNot(contains('no device')));
    });

    test('a request Nexus has no ability for is its own reason', () {
      final service = _service(devices: [_phone()]);
      _ask(service, 'generate an image of a cat');
      final text = _text(_ask(service, 'why can\'t you do this'));
      expect(text, contains('Nexus has no such ability at all'));
      expect(
        text,
        isNot(contains('no device you have')),
        reason: 'the ability does not exist anywhere, which is different',
      );
    });

    test('a request no known device holds names the reach, from the registry',
        () {
      // Flashlight is declared phone-only, so a desktop-only world cannot run
      // it and the registry — not a status — is what says why.
      final service = _service();
      _ask(service, 'flashlight on');
      final text = _text(_ask(service, 'why can\'t you do this'));
      expect(text, contains('I understood it as Flashlight'));
      expect(text, contains('no device you have says it can do that'));
      expect(text, contains('it takes a phone'));
    });

    test('pairing the device that can do it changes the answer', () {
      final service = _service(devices: [_phone()]);
      _ask(service, 'flashlight on');
      final text = _text(_ask(service, 'why can\'t you do this'));
      expect(
        text,
        isNot(contains('no device you have says it can do that')),
        reason: 'a phone that lists the flashlight is a device you have',
      );
    });

    test('an action Nexus answers by itself is never "no device can"', () {
      final service = _service();
      _ask(service, 'what time is it');
      expect(
        _text(_ask(service, 'why can\'t you do this')),
        contains('Nothing has failed'),
        reason: 'the time has no device backend to be missing',
      );
    });

    test('a reachable holder is reported, with the reason left unattributed',
        () {
      // The request failed while the ability really exists here, so blaming a
      // missing device would be a cause the failure never had.
      final service = _service(devices: [_phone()]);
      _ask(service, 'blink the esp32');
      final text = _text(_ask(service, 'why can\'t you do this'));
      expect(text, contains('I can\'t say why from the record'));
      expect(text, contains('a missing device was not the reason'));
      expect(text, contains('What I said'));
    });

    test('a refusal is the user\'s decision, never a missing capability', () {
      final service = _service(devices: [_phone()]);
      final asked = _ask(service, 'copy hello to my devices');
      expect(
        asked.status,
        AgentResultStatus.required,
        reason: 'clipboard pushes need approval',
      );
      final text = _text(_ask(service, 'why can\'t you do this'));
      expect(text, contains('still waiting for your go-ahead'));
      expect(text, contains('What I said: "Local approval is required."'));
      expect(
        text,
        isNot(contains('no device')),
        reason: 'the device can do it — the user has not said yes yet',
      );
    });

    test('a success clears the record, so the answer cannot go stale', () {
      final service = _service(devices: [_phone()]);
      _ask(service, 'generate an image of a cat');
      expect(
        _text(_ask(service, 'why can\'t you do this')),
        contains('Nexus has no such ability'),
      );
      _ask(service, 'what time is it');
      expect(
        _text(_ask(service, 'why can\'t you do this')),
        contains('Nothing has failed'),
      );
    });

    test('every one of the four reasons is reachable from a real request',
        () {
      // A reason nothing can produce would be vocabulary pretending to be
      // capability, so each one is pinned to the request that really yields
      // it — through the same surface a user types into.
      final notUnderstood = _service();
      notUnderstood.execute('teleport me to mars');
      expect(
        _text(notUnderstood.execute('why can\'t you do this')),
        contains('I didn\'t understand'),
      );

      final noSuchCapability = _service();
      noSuchCapability.execute('generate an image of a cat');
      expect(
        _text(noSuchCapability.execute('why can\'t you do this')),
        contains('no such ability at all'),
      );

      final noCapableDevice = _service();
      noCapableDevice.execute('flashlight on');
      expect(
        _text(noCapableDevice.execute('why can\'t you do this')),
        contains('no device you have says it can do that'),
      );

      final notAuthorized = _service(devices: [_phone()]);
      notAuthorized.execute('copy hello to my devices');
      expect(
        _text(notAuthorized.execute('why can\'t you do this')),
        contains('your go-ahead'),
      );
    });

    test('a question is neither a success nor a failure', () {
      final service = _service(devices: [_phone()]);
      _ask(service, 'generate an image of a cat');
      // Asking the user something does not overwrite what is being explained.
      _ask(service, 'call mom');
      expect(
        _text(_ask(service, 'why can\'t you do this')),
        isNot(contains('Nothing has failed')),
      );
    });
  });
}
