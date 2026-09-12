import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';

void main() {
  const phone = DeviceCapabilities(deviceId: 'phone');
  const esp = DeviceCapabilities(
    deviceId: 'esp32',
    capabilities: [DeviceCapability(AgentActions.ledBlink)],
  );

  test('contracts round-trip', () {
    const caps = DeviceCapabilities(
      deviceId: 'esp32',
      capabilities: [DeviceCapability(AgentActions.ledBlink, version: 2)],
    );
    expect(DeviceCapabilities.fromJson(caps.toJson()).toJson(), caps.toJson());
    const request = AgentRequest(
      requestId: 'r1', target: 'esp32', action: AgentActions.ledBlink,
      arguments: {'blink': true}, approval: AgentApproval.approved,
    );
    expect(AgentRequest.fromJson(request.toJson()).toJson(), request.toJson());
  });

  test('parse supported commands only', () {
    final cases = <String, ParsedCommand?>{
      'show my devices': const ParsedCommand(action: AgentActions.deviceList, target: 'local'),
      ' BLINK THE ESP32 ': const ParsedCommand(action: AgentActions.ledBlink, target: 'esp32'),
      'unsupported command': null,
    };
    for (final entry in cases.entries) {
      expect(parseCommand(entry.key)?.action, entry.value?.action, reason: entry.key);
      expect(parseCommand(entry.key)?.target, entry.value?.target, reason: entry.key);
    }
  });

  test('dispatch returns snapshots or a validated dry-run plan', () {
    const snapshots = [
      AgentDeviceSnapshot(id: 'phone', name: 'My phone', online: true),
      AgentDeviceSnapshot(id: 'esp32', name: 'Desk ESP32', online: false),
    ];
    final list = dispatchCommand(
      command: const ParsedCommand(action: AgentActions.deviceList, target: 'local'),
      devices: snapshots,
    );
    expect(list.status, AgentResultStatus.succeeded);
    expect((list.dispatch! as AgentDeviceList).devices, orderedEquals(snapshots));

    final cases = <String, ({AgentApproval approval, DeviceCapabilities? target, AgentResultStatus status})>{
      'required': (approval: AgentApproval.required, target: esp, status: AgentResultStatus.required),
      'denied': (approval: AgentApproval.denied, target: esp, status: AgentResultStatus.denied),
      'missing target': (approval: AgentApproval.approved, target: null, status: AgentResultStatus.unavailable),
      'missing capability': (approval: AgentApproval.approved, target: phone, status: AgentResultStatus.unavailable),
      'old capability': (approval: AgentApproval.approved, target: const DeviceCapabilities(deviceId: 'esp32', capabilities: [DeviceCapability(AgentActions.ledBlink, version: 0)]), status: AgentResultStatus.unavailable),
    };
    for (final entry in cases.entries) {
      final result = dispatchCommand(
        command: const ParsedCommand(action: AgentActions.ledBlink, target: 'esp32'),
        targetDevice: entry.value.target,
        approval: entry.value.approval,
        requestId: entry.key,
      );
      expect(result.status, entry.value.status, reason: entry.key);
      expect(result.dispatch, isNull, reason: entry.key);
    }

    final success = dispatchCommand(
      command: const ParsedCommand(action: AgentActions.ledBlink, target: 'esp32'),
      targetDevice: esp,
      approval: AgentApproval.approved,
      requestId: 'blink-1',
    );
    final plan = (success.dispatch! as AgentActionPlan).request;
    expect(success.status, AgentResultStatus.succeeded);
    expect(plan.requestId, 'blink-1');
    expect(plan.target, 'esp32');
    expect(plan.approval, AgentApproval.approved);
    expect(plan.isAuthorized(esp), isTrue);
    expect(plan.isAuthorized(const DeviceCapabilities(deviceId: 'esp32')), isFalse);
  });

  group('a status always explains itself', () {
    test('no status other than success is ever a bare verdict', () {
      for (final status in AgentResultStatus.values) {
        final bare = status.explain();
        if (status == AgentResultStatus.succeeded) {
          expect(bare, isEmpty, reason: 'success needs no apology');
          continue;
        }
        // A bare label is the thing the user should never see: "Unavailable"
        // on its own says nothing about what is missing, and reads as the app
        // pretending it tried. Every other status has to explain itself.
        expect(bare, isNotEmpty, reason: status.name);
        expect(
          bare.toLowerCase(),
          isNot(equals(status.name.toLowerCase())),
          reason: '${status.name} must say more than its own name',
        );
        expect(bare.length, greaterThan(15), reason: status.name);
      }
    });

    test('every status can name itself and describe a device\'s outcome', () {
      for (final status in AgentResultStatus.values) {
        expect(status.label, isNotEmpty, reason: status.name);
        // The remote report is a full sentence that names the device, never a
        // fragment waiting to be glued onto one.
        final report = status.reportFrom('TVcraft\'s phone');
        expect(report, contains('TVcraft\'s phone'), reason: status.name);
        expect(report.trim(), endsWith('.'), reason: status.name);
        // The chip label is a verdict, not a sentence: the explanation and the
        // chip must not be the same words, or the chip has stopped explaining.
        expect(status.label, isNot(equals(status.explain())), reason: status.name);
      }
      // The chip labels are what the user already reads; they are part of the
      // interface, not an implementation detail to be reworded freely.
      expect(AgentResultStatus.needsInfo.label, 'Question');
      expect(AgentResultStatus.required.label, 'Approval needed');
      expect(AgentResultStatus.unavailable.label, 'Unavailable');
    });

    test('only a genuine could-not-do is a failure', () {
      // The core's error state reads exactly this predicate, so the whole
      // "what is an error" decision is one line here and one call site
      // there. Only `unavailable` means Nexus tried and could not.
      expect(AgentResultStatus.unavailable.isFailure, isTrue);
      for (final status in const [
        AgentResultStatus.succeeded,
        AgentResultStatus.needsInfo,
        // The two that look most like failures and are not: a no the user
        // gave, and a gate they have not answered yet.
        AgentResultStatus.denied,
        AgentResultStatus.required,
      ]) {
        expect(status.isFailure, isFalse, reason: status.name);
      }
    });

    test('exactly one status is Nexus asking rather than reporting', () {
      // `needsInfo` is the clarification the brief names: the request needs
      // something from the user. Reading its chip as a verdict is what made
      // "Who should I call?" arrive under the label "Unavailable".
      expect(AgentResultStatus.needsInfo.isQuestion, isTrue);
      for (final status in AgentResultStatus.values) {
        if (status == AgentResultStatus.needsInfo) continue;
        expect(status.isQuestion, isFalse, reason: status.name);
      }
      // A question is not a failure, and it carries the words of the chip.
      expect(AgentResultStatus.needsInfo.isFailure, isFalse);
      expect(AgentResultStatus.needsInfo.label, 'Question');
    });

    test('a real reason is passed through untouched', () {
      const reason =
          'I can\'t open email on this device — try on a device with a mail app.';
      expect(AgentResultStatus.unavailable.explain(reason), reason);
    });

    test('whitespace is not a reason', () {
      expect(AgentResultStatus.unavailable.explain('   '), isNotEmpty);
      expect(
        AgentResultStatus.unavailable.explain('   '),
        isNot(equals('   ')),
      );
    });
  });

  group('reporting what a paired device did', () {
    const device = "TVcraft's phone";

    test('a failure with no reason is attributed to the device, not glued '
        'onto a delivery claim', () {
      final said = AgentResultStatus.unavailable.reportFrom(device);
      // The defect this replaces: the caller prefixed a bare fragment with
      // "Sent to ", producing "Sent to TVcraft's phone — it could not do it."
      // — a sentence that contradicts itself and explains nothing.
      expect(said, isNot(contains('Sent to')));
      expect(said, contains(device));
      expect(said, isNot(contains('I ')), reason: 'not this device\'s voice');
      expect(said, isNot(contains('this device')));
    });

    test('the device\'s own words come first, then its own reason', () {
      expect(
        AgentResultStatus.unavailable.reportFrom(
          device,
          message: 'no mail app',
          words: "I can't open email here.",
        ),
        "$device — I can't open email here.",
      );
      expect(
        AgentResultStatus.unavailable.reportFrom(device, message: 'no mail app'),
        '$device — no mail app',
      );
    });

    test('success keeps the delivery claim it earned', () {
      expect(
        AgentResultStatus.succeeded.reportFrom(device, words: 'Opened.'),
        'Sent to $device — Opened.',
      );
      expect(
        AgentResultStatus.succeeded.reportFrom(device),
        'Sent to $device — done.',
      );
    });

    test('nothing is invented when there is no reason', () {
      for (final status in AgentResultStatus.values) {
        final said = status.reportFrom(device);
        expect(said, contains(device), reason: status.name);
        expect(said.trim(), endsWith('.'), reason: status.name);
      }
      // Whitespace is not a reason either.
      expect(
        AgentResultStatus.unavailable.reportFrom(device, message: '   '),
        AgentResultStatus.unavailable.reportFrom(device),
      );
      // The local explanation is deliberately NOT reused here: it says what
      // *this* device can do, which would be a false claim about the peer.
      expect(
        AgentResultStatus.unavailable.reportFrom(device),
        isNot(AgentResultStatus.unavailable.explain()),
      );
    });
  });
}
