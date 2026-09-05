import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/phone_actions.dart';

class FakePhoneBackend implements PhoneActionBackend {
  final Map<String, String> contacts;
  bool fail = false;

  /// When true a resolved contact is called directly instead of opening the
  /// prefilled dialer.
  bool directCall = false;

  /// Closest names offered when nothing matches — the teach-me flow's input.
  List<String> candidatesOnMiss = const [];

  String? lastDialed;
  String? lastNumber;

  FakePhoneBackend(this.contacts);

  @override
  Future<PhoneCallOutcome> videoCall(String name, String? app) async {
    lastDialed = name;
    if (fail) throw Exception('boom');
    return PhoneCallOutcome(
      placed: false,
      launched: app != null && app.isNotEmpty,
      message: app == null
          ? 'I only start video calls in an app you name.'
          : 'Opened $app with $name.',
    );
  }

  @override
  Future<PhoneCallOutcome> callContact(String name, {String? number}) async {
    lastDialed = name;
    final taught = number;
    lastNumber = taught;
    if (fail) throw Exception('boom');
    // A taught number skips the address book, exactly like MainActivity.kt.
    if (taught != null) {
      return PhoneCallOutcome(
        placed: true,
        number: taught,
        message: 'Calling $name ($taught).',
      );
    }
    // Mirrors the native matcher in MainActivity.kt (exact first, then
    // case-insensitive prefix/contains) so the Dart side exercises the same
    // resolution contract end-to-end.
    final matchedName = _bestContactMatch(contacts.keys, name);
    final resolved = matchedName == null ? null : contacts[matchedName];
    if (resolved == null) {
      return PhoneCallOutcome(
        placed: false,
        candidates: candidatesOnMiss,
        message: 'No contact named "$name" on this device.',
      );
    }
    if (directCall) {
      return PhoneCallOutcome(
        placed: true,
        number: resolved,
        message: 'Calling $matchedName ($resolved).',
      );
    }
    return PhoneCallOutcome(
      placed: false,
      launched: true,
      number: resolved,
      message: 'Opened the dialer for $matchedName ($resolved).',
    );
  }
}

/// Exact match wins; then case-insensitive full match, prefix, contains.
/// Mirrors `pickBestContactMatch` in MainActivity.kt.
String? _bestContactMatch(Iterable<String> names, String query) {
  final q = query.trim();
  if (q.isEmpty) return null;
  final lower = q.toLowerCase();
  for (final name in names) {
    if (name == q) return name;
  }
  for (final name in names) {
    if (name.toLowerCase() == lower) return name;
  }
  for (final name in names) {
    if (name.toLowerCase().startsWith(lower)) return name;
  }
  for (final name in names) {
    if (name.toLowerCase().contains(lower)) return name;
  }
  return null;
}

void main() {
  const request = AgentRequest(
    requestId: 'r1',
    target: 'phone1',
    action: AgentActions.callPlace,
    arguments: {'contact': 'mom'},
    approval: AgentApproval.approved,
  );

  test(
    'resolves the contact and opens the dialer, confirming the launch',
    () async {
      final backend = FakePhoneBackend({'mom': '+33612345678'});
      final result = await executePhoneCall(backend, request);

      expect(backend.lastDialed, 'mom');
      expect(result.status, AgentResultStatus.succeeded);
      final message = result.dispatch! as AgentMessage;
      expect(message.text, contains('mom'));
      expect(message.text, contains('+33612345678'));
    },
  );

  test('an unknown contact is an honest unavailable, never a crash', () async {
    final backend = FakePhoneBackend({});
    final result = await executePhoneCall(backend, request);

    expect(result.status, AgentResultStatus.unavailable);
    expect(result.dispatch, isNull);
    expect(result.message, contains('mom'));
  });

  test('an exact display-name match wins over partial candidates', () async {
    final backend = FakePhoneBackend({
      'TVcraft01 〘✘ΔτΚ⑤⑦〙': '0652544264',
      'tvcraft01': '0600000000', // also matches case-insensitively…
      'TVCRAFT01': '0611111111', // …but the exact match must win.
    });
    final result = await executePhoneCall(
      backend,
      const AgentRequest(
        requestId: 'r3',
        target: 'phone1',
        action: AgentActions.callPlace,
        arguments: {'contact': 'TVCRAFT01'},
        approval: AgentApproval.approved,
      ),
    );

    expect(result.status, AgentResultStatus.succeeded);
    final message = result.dispatch! as AgentMessage;
    // The exactly-named contact's own number must be dialed, not a partial
    // candidate like the decorated "TVcraft01 〘✘ΔτΚ⑤⑦〙".
    expect(message.text, contains('0611111111'));
    expect(message.text, isNot(contains('0652544264')));
  });

  test(
    'a decorated contact resolves through the fallback (real-device case)',
    () async {
      // The real phone stores the contact as "TVcraft01 〘✘ΔτΚ⑤⑦〙"; asking for
      // "TVcraft01" used to miss with an exact-only lookup.
      final backend = FakePhoneBackend({
        'TVcraft01 〘✘ΔτΚ⑤⑦〙': '0652544264',
        'Mom': '+33612345678',
      });
      final result = await executePhoneCall(
        backend,
        const AgentRequest(
          requestId: 'r4',
          target: 'phone1',
          action: AgentActions.callPlace,
          arguments: {'contact': 'TVcraft01'},
          approval: AgentApproval.approved,
        ),
      );

      expect(result.status, AgentResultStatus.succeeded);
      final message = result.dispatch! as AgentMessage;
      expect(message.text, contains('0652544264'));
      expect(message.text, contains('TVcraft01'));
    },
  );

  test('a directly-placed call maps to succeeded', () async {
    final backend = FakePhoneBackend({'mom': '+33612345678'})
      ..directCall = true;
    final result = await executePhoneCall(backend, request);

    expect(result.status, AgentResultStatus.succeeded);
    expect((result.dispatch! as AgentMessage).text, contains('Calling mom'));
  });

  test('closest candidates ride along so the wording can be taught', () async {
    final backend = FakePhoneBackend({})
      ..candidatesOnMiss = const ['TVcraft01 〘✘ΔτΚ⑤⑦〙', 'Tonton Juju'];
    final result = await executePhoneCall(backend, request);

    expect(result.status, AgentResultStatus.unavailable);
    expect(result.dispatch, isNull);
    expect(backend.candidatesOnMiss, contains('TVcraft01 〘✘ΔτΚ⑤⑦〙'));
  });

  test('a failing backend is reported, not thrown', () async {
    final backend = FakePhoneBackend({'mom': '+33612345678'})..fail = true;
    final result = await executePhoneCall(backend, request);

    expect(result.status, AgentResultStatus.unavailable);
    expect(result.message, isNotEmpty);
  });

  test('a missing contact argument is unavailable', () async {
    final backend = FakePhoneBackend({});
    final result = await executePhoneCall(
      backend,
      const AgentRequest(
        requestId: 'r2',
        target: 'phone1',
        action: AgentActions.callPlace,
        approval: AgentApproval.approved,
      ),
    );

    expect(result.status, AgentResultStatus.unavailable);
    expect(result.message, contains('No contact'));
  });
}
