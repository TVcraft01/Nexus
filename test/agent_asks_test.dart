// The ask Nexus raises when a sentence named the action but not the contact is
// one question, and the whole of it is [AgentAsks]: the interpreter asks before
// dispatch ("text on my phone"), the catalogue asks when a dispatched command
// reached it with no contact, and a device agent asks when its own address book
// needs the name. Three layers, one wording — and this guard is what keeps it
// one, because the next site to need it would otherwise reach for a copy.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/command_service.dart';

void main() {
  const asks = [AgentAsks.whoToCall, AgentAsks.whoToText, AgentAsks.whoToEmail];

  test('each ask is declared once, in the contract it belongs to', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      // The one owner. Read rather than restated everywhere else.
      if (entity.path.endsWith('core/agent_contract.dart')) continue;
      for (final line in entity.readAsLinesSync()) {
        final code = line.trimLeft();
        // Comments are how the wording is discussed; only what the app can
        // actually say to a user is in scope.
        if (code.startsWith('//') || code.startsWith('*')) continue;
        for (final ask in asks) {
          if (code.contains(ask)) offenders.add('${entity.path}: $ask');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'the ask wording has one owner (AgentAsks): a second copy is how the '
          'interpreter, the catalogue and a device agent end up asking the same '
          'question three different ways',
    );
  });

  test('and the question the user is asked is that wording', () {
    // Through the real service, for the layer that asks before dispatch: the
    // question the card shows is the clarification's own, and it is the shared
    // wording rather than a sentence this layer wrote for itself.
    final service = CommandService(devices: () => const []);
    for (final entry in const {
      'text on my phone': AgentAsks.whoToText,
      'call on my phone': AgentAsks.whoToCall,
    }.entries) {
      final result = service.execute(entry.key);
      expect(result.status, AgentResultStatus.needsInfo, reason: entry.key);
      final dispatch = result.dispatch;
      expect(dispatch, isA<AgentClarification>(), reason: entry.key);
      expect(
        (dispatch as AgentClarification).question,
        entry.value,
        reason: entry.key,
      );
    }
  });
}
