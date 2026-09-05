import 'package:flutter/services.dart' show MethodChannel;

import 'agent_contract.dart';

/// Outcome of asking the device to call a contact.
class PhoneCallOutcome {
  /// True when the call itself was started — no further taps needed.
  final bool placed;

  /// True when only the prefilled dialer could be opened (CALL_PHONE
  /// unavailable or the direct call failed).
  final bool launched;

  /// The resolved phone number, when found.
  final String? number;

  /// Closest contact names when nothing was called. The assistant offers
  /// these so the user can teach it which one they meant.
  final List<String> candidates;

  /// Human-readable detail ("Calling mom (+33…)").
  final String message;

  const PhoneCallOutcome({
    required this.placed,
    this.launched = false,
    this.number,
    this.candidates = const [],
    required this.message,
  });
}

/// The platform side of a phone action. Android resolves the contact and
/// places the call; other platforms answer honestly that phone actions are
/// unavailable.
abstract class PhoneActionBackend {
  /// Calls [name] — resolved against the device address book unless
  /// [number] is given (a taught fact), which skips contact lookup.
  Future<PhoneCallOutcome> callContact(String name, {String? number});

  /// Video call in the app the user named. Only WhatsApp and Telegram can
  /// land on a callable contact; other apps (and no app at all) are
  /// answered honestly.
  Future<PhoneCallOutcome> videoCall(String name, String? app);
}

/// Real backend: talks to the `dev.nexus.nexus/phone` channel; answers
/// honestly instead of throwing when it is missing (not Android, tests).
class RealPhoneActionBackend implements PhoneActionBackend {
  static const _channel = MethodChannel('dev.nexus.nexus/phone');

  static const _unavailable = PhoneCallOutcome(
    placed: false,
    message: 'Phone actions are not available on this device.',
  );

  @override
  Future<PhoneCallOutcome> callContact(String name, {String? number}) async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'callContact',
        {'name': name, 'number': ?number},
      );
      if (raw == null) return _unavailable;
      return PhoneCallOutcome(
        placed: raw['placed'] == true,
        launched: raw['launched'] == true,
        number: raw['number']?.toString(),
        candidates: (raw['candidates'] as List<dynamic>? ?? const [])
            .map((c) => c.toString())
            .toList(),
        message: raw['message']?.toString() ?? '',
      );
    } catch (_) {
      return _unavailable;
    }
  }

  @override
  Future<PhoneCallOutcome> videoCall(String name, String? app) async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('videoCall', {
        'name': name,
        'app': app,
      });
      if (raw == null) return _unavailable;
      return PhoneCallOutcome(
        placed: raw['placed'] == true,
        launched: raw['launched'] == true,
        number: raw['number']?.toString(),
        candidates: (raw['candidates'] as List<dynamic>? ?? const [])
            .map((c) => c.toString())
            .toList(),
        message: raw['message']?.toString() ?? '',
      );
    } catch (_) {
      return _unavailable;
    }
  }
}

/// Executes a `communication.call` request on this device: resolve the
/// contact and place the call (or open the dialer as fallback). The typed
/// outcome travels back to the requester as the agent.result reply.
Future<AgentDispatchResult> executePhoneCall(
  PhoneActionBackend backend,
  AgentRequest request,
) async {
  final contact = request.arguments['contact']?.toString().trim() ?? '';
  if (contact.isEmpty) {
    return const AgentDispatchResult(
      status: AgentResultStatus.unavailable,
      message: 'No contact was named in the call request.',
    );
  }
  final PhoneCallOutcome outcome;
  try {
    outcome = await backend.callContact(contact);
  } catch (_) {
    return const AgentDispatchResult(
      status: AgentResultStatus.unavailable,
      message: 'The call could not be placed on this device.',
    );
  }
  final ok = outcome.placed || outcome.launched;
  return AgentDispatchResult(
    status: ok ? AgentResultStatus.succeeded : AgentResultStatus.unavailable,
    dispatch: ok ? AgentMessage(outcome.message) : null,
    message: ok ? '' : outcome.message,
  );
}
