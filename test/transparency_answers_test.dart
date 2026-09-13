// The two transparency questions the brief names, driven through the real
// service: "why did you do that?" explained from the record of what Nexus
// actually did, and "what did you infer?" answered honestly by a system that
// infers nothing.
//
// Three things are pinned here and nothing else:
//   1. the answers reflect the real last action, not a story about it;
//   2. they can never claim a history that did not happen — no action where
//      nothing ran, no device where none could be named;
//   3. an inference is never stated as a certainty.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/capability.dart';
import 'package:nexus/core/command_service.dart';
import 'package:nexus/core/memory.dart';

CommandService _service({
  AgentMemory memory = const AgentMemory(),
  List<AgentDeviceSnapshot> devices = const [],
  bool withLocal = true,
}) => CommandService(
  devices: () => devices,
  memory: memory,
  local: withLocal
      ? AgentDeviceSnapshot(
          id: 'd1',
          name: 'Test Desk',
          online: true,
          capabilities: defaultCapabilitiesFor('linux'),
          platform: 'linux',
        )
      : null,
  locallyExecutable: const {'search.web', 'time.get'},
);

AgentDeviceSnapshot _phone() => AgentDeviceSnapshot(
  id: 'p1',
  name: 'Pixel 8',
  online: true,
  capabilities: defaultCapabilitiesFor('android'),
  platform: 'android',
);

String _said(CommandService service, String input) {
  final result = service.execute(input);
  final dispatch = result.dispatch;
  if (dispatch is AgentMessage) return dispatch.text;
  return result.message;
}

/// Teaches [phrase] to mean [meaning] through the real two-turn flow.
void _teach(CommandService service, String phrase, String meaning) {
  final asked = service.execute(phrase);
  final clarification = asked.dispatch;
  expect(clarification, isA<AgentClarification>());
  service.execute(meaning, answerTo: (clarification! as AgentClarification).key);
}

void main() {
  group('"why did you do that" explains the real last action', () {
    test('with nothing done it says so instead of inventing a history', () {
      final text = _said(_service(), 'why did you do that');
      expect(text, contains('I haven\'t done anything yet'));
      expect(text, contains('nothing to explain'));
      expect(text, isNot(contains('I understood it as')));
    });

    test('it names the sentence, the capability, the device and the outcome',
        () {
      final service = _service();
      service.execute('what time is it');
      final text = _said(service, 'why did you do that');
      expect(text, contains('You said "what time is it"'));
      expect(text, contains('I understood it as Time'));
      expect(text, contains('Test Desk ran it'));
      expect(text, contains('It came off: "It\'s'));
    });

    test('a phrase the user taught is attributed to them, in their words', () {
      final service = _service();
      _teach(service, 'zap the toaster', 'show my devices');
      service.execute('zap the toaster');
      final text = _said(service, 'why did you do that');
      expect(text, contains('You said "zap the toaster"'));
      expect(text, contains('a phrase you taught me'));
      expect(text, contains('it means Devices'));
    });

    test('a sentence it never understood does not become an action', () {
      final service = _service();
      service.execute('teleport me to mars');
      final text = _said(service, 'why did you do that');
      expect(text, contains('I never understood it, so nothing was attempted'));
      expect(text, contains('What I said'));
      expect(
        text,
        isNot(contains('ran it')),
        reason: 'nothing ran, and the answer may not claim otherwise',
      );
      expect(text, isNot(contains('It came off')));
    });

    test('a request it has no ability for says exactly that', () {
      final service = _service();
      service.execute('generate an image of a cat');
      final text = _said(service, 'why did you do that');
      expect(text, contains('Nexus has no ability for it at all'));
      expect(text, contains('nothing ran'));
      expect(text, isNot(contains('ran it.')));
    });

    test('a question is reported as a question, never as an action', () {
      final service = _service();
      service.execute('set a timer');
      final text = _said(service, 'why did you do that');
      expect(text, contains('Nothing ran — I asked you something instead'));
      expect(text, contains('What I asked: "How long should the timer run?"'));
      expect(text, isNot(contains('ran it')));
    });

    test('it names no device when none could be named', () {
      final service = _service(withLocal: false);
      service.execute('what time is it');
      final text = _said(service, 'why did you do that');
      expect(text, contains('I understood it as Time'));
      expect(
        text,
        isNot(contains('ran it')),
        reason: 'there is no device to name, so none is named',
      );
    });

    test('asking about the action does not replace it', () {
      final service = _service();
      service.execute('what time is it');
      final first = _said(service, 'why did you do that');
      final second = _said(service, 'why did you do that');
      expect(second, first);
      expect(second, contains('what time is it'));
    });
  });

  group('"why did you do that" reports the real failure reason', () {
    test('a capability no device here holds is named, from the registry', () {
      final service = _service();
      service.execute('flashlight on');
      final text = _said(service, 'why did you do that');
      expect(text, contains('nothing ran it'));
      expect(text, contains('No device you have says it can do that'));
      expect(text, contains('it takes a phone'));
    });

    test('a failure it cannot attribute invents no cause', () {
      final service = _service();
      final result = service.execute('blink the esp32');
      expect(result.status, AgentResultStatus.unavailable);
      final text = _said(service, 'why did you do that');
      expect(text, contains('I can\'t say why from the record'));
      expect(text, contains('a missing device was not the reason'));
      expect(text, contains('What I said'));
    });

    test('a go-ahead not yet given is the user\'s, not a missing ability', () {
      final service = _service(devices: [_phone()]);
      final result = service.execute('copy hello to my devices');
      expect(result.status, AgentResultStatus.required);
      final text = _said(service, 'why did you do that');
      expect(text, contains('still waiting for your go-ahead'));
      expect(text, isNot(contains('no device')));
    });

    test('the two answers describe the same failure with the same words', () {
      final service = _service();
      service.execute('flashlight on');
      final cause = _said(service, 'why did you do that');
      final whyCant = _said(service, 'why can\'t you do this');
      // Both explanations come from one reason sentence, so neither can drift
      // into a different story about the same failure.
      expect(cause, contains('No device you have says it can do that'));
      expect(whyCant, contains('No device you have says it can do that'));
      expect(whyCant, contains('The last thing you asked me was "flashlight on"'));
    });
  });

  group('"what did you infer" is honest about a system that infers nothing', () {
    test('with nothing stored it says nothing is inferred and nothing is held',
        () {
      final text = _said(_service(), 'what did you infer');
      expect(text, contains('I haven\'t inferred anything about you'));
      expect(text, contains('I hold nothing about you at all right now'));
    });

    test('it counts what is really stored, by the origin it was stored with',
        () {
      final service = _service();
      service.execute('remember that my bike code is 4321');
      _teach(service, 'zap the toaster', 'show my devices');
      service.adoptFact('my keys are in the hall', from: 'Pixel 8');
      final text = _said(service, 'what did you infer');
      expect(text, contains('I haven\'t inferred anything about you'));
      expect(text, contains('• you told me: 2'));
      expect(text, contains('• from a device: 1'));
      expect(
        text,
        isNot(contains('inferred: ')),
        reason: 'no inferred entry exists, so none is reported',
      );
    });

    test('the count is not stale — learning something new changes it', () {
      final service = _service();
      expect(_said(service, 'what did you infer'), isNot(contains('you told me')));
      service.execute('remember that my bike code is 4321');
      expect(_said(service, 'what did you infer'), contains('you told me: 1'));
      service.execute('remember that my wifi password is nexus');
      expect(_said(service, 'what did you infer'), contains('you told me: 2'));
    });

    test('an inference is reported as an inference, never as a fact', () {
      // Nothing in Nexus creates one — but the model can hold one, and if it
      // ever does the answer must not present it as knowledge.
      final service = _service(
        memory: AgentMemory(
          facts: [
            MemoryFact(
              'you are about to run out of milk',
              MemoryStamp(
                origin: MemoryOrigin.inferred,
                source: 'your shopping routine',
                learnedAt: DateTime(2026, 9, 13),
                inferredFrom: 'repeated shopping-list entries',
              ),
            ),
          ],
        ),
      );
      final text = _said(service, 'what did you infer');
      expect(text, contains('came from an inference, not from anything'));
      expect(text, contains('I may be wrong about any of them'));
      expect(text, contains('• inferred: 1'));
      expect(
        text,
        isNot(contains('I haven\'t inferred anything')),
        reason: 'the headline may not deny an inference that exists',
      );
    });

    test('answering it does not turn the inference into a fact elsewhere', () {
      final service = _service(
        memory: AgentMemory(
          facts: [
            MemoryFact(
              'you are about to run out of milk',
              MemoryStamp(
                origin: MemoryOrigin.inferred,
                source: 'your shopping routine',
                learnedAt: DateTime(2026, 9, 13),
                inferredFrom: 'repeated shopping-list entries',
              ),
            ),
          ],
        ),
      );
      // The recall list carries its own wording, and it says "I inferred this"
      // rather than asserting the thing.
      final recall = _said(service, 'what do you know about me');
      expect(recall, contains('I inferred this from your shopping routine'));
    });
  });

  group('the two questions resolve, and nothing else is taken with them', () {
    test('the brief\'s phrasings all reach an answer', () {
      final service = _service();
      for (final phrasing in [
        'why did you do that',
        'why did you do that?',
        'what did you just do',
        'what did you do',
        'why do you do that',
      ]) {
        expect(
          _said(service, phrasing),
          contains('I haven\'t done anything yet'),
          reason: '"$phrasing" must reach the action answer',
        );
      }
      for (final phrasing in [
        'what did you infer',
        'what did you infer?',
        'what have you inferred',
        'did you infer anything',
        'what have you assumed',
      ]) {
        expect(
          _said(service, phrasing),
          contains('I haven\'t inferred anything'),
          reason: '"$phrasing" must reach the inference answer',
        );
      }
    });

    test('memory provenance still answers its own question', () {
      final service = _service();
      service.execute('remember that my bike code is 4321');
      final text = _said(service, 'why do you know that about my bike code');
      expect(text, contains('you told me this on Test Desk'));
      expect(
        text,
        isNot(contains('You said "why do you know that')),
        reason: 'provenance must not become an action report',
      );
    });

    test('an unrelated "why do you …" question is not claimed', () {
      final service = _service();
      for (final phrasing in [
        'why do you like that',
        'what did you say',
        'why do you know that',
      ]) {
        expect(
          _said(service, phrasing),
          isNot(contains('You said "')),
          reason: '"$phrasing" is not a question about an action',
        );
      }
    });
  });
}
