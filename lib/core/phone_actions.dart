import 'package:flutter/services.dart' show MethodChannel;

import 'agent_contract.dart';

/// Outcome of asking the device to call a contact.
class PhoneCallOutcome {
  /// True when the system dialer opened with the number prefilled.
  final bool launched;

  /// The resolved phone number, when found.
  final String? number;

  /// Human-readable detail ("No contact named \"mom\"…").
  final String message;

  const PhoneCallOutcome({
    required this.launched,
    this.number,
    required this.message,
  });
}

/// The platform side of a phone action. Android resolves the contact and
/// opens the dialer (see MainActivity); other platforms answer honestly that
/// phone actions are unavailable.
abstract class PhoneActionBackend {
  Future<PhoneCallOutcome> dialContact(String name);
}

/// Real backend: talks to the `dev.nexus.nexus/phone` channel; answers
/// honestly instead of throwing when it is missing (not Android, tests).
class RealPhoneActionBackend implements PhoneActionBackend {
  static const _channel = MethodChannel('dev.nexus.nexus/phone');

  static const _unavailable = PhoneCallOutcome(
    launched: false,
    message: 'Phone actions are not available on this device.',
  );

  @override
  Future<PhoneCallOutcome> dialContact(String name) async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'dialContact',
        {'name': name},
      );
      if (raw == null) return _unavailable;
      return PhoneCallOutcome(
        launched: raw['launched'] == true,
        number: raw['number']?.toString(),
        message: raw['message']?.toString() ?? '',
      );
    } catch (_) {
      return _unavailable;
    }
  }
}

/// Executes a `communication.call` request on this device: resolve the
/// contact and open the dialer. The typed outcome travels back to the
/// requester as the agent.result reply.
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
    outcome = await backend.dialContact(contact);
  } catch (_) {
    return const AgentDispatchResult(
      status: AgentResultStatus.unavailable,
      message: 'The call could not be placed on this device.',
    );
  }
  return AgentDispatchResult(
    status: outcome.launched
        ? AgentResultStatus.succeeded
        : AgentResultStatus.unavailable,
    dispatch: outcome.launched ? AgentMessage(outcome.message) : null,
    message: outcome.launched ? '' : outcome.message,
  );
}
