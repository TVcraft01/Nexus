// The scripted model and the two conversations' scripts.
//
// No network and no model: the backend answers from a map keyed by the ask the
// prompt carries, and streams it in chunks the way a real one would. A prompt
// the script does not know throws, so a conversation that starts asking
// something new fails loudly instead of quietly planning nothing.
import 'package:nexus/core/local_ai_service.dart';
import 'package:nexus/core/text_generation_backend.dart';

class ScriptedBackend implements TextGenerationBackend {
  ScriptedBackend(this.byAsk);

  /// Reply, keyed by a fragment the prompt must contain — `The ask: …`.
  final Map<String, String> byAsk;

  /// Every prompt the model was shown, in order.
  final List<String> prompts = <String>[];

  @override
  Stream<String> generateStream(String prompt, {List<AiTurn>? history}) async* {
    prompts.add(prompt);
    final key = byAsk.keys.firstWhere(
      (fragment) => prompt.contains(fragment),
      orElse: () => '',
    );
    if (key.isEmpty) {
      throw StateError('the scripted model has no reply for:\n$prompt');
    }
    final reply = byAsk[key]!;
    const chunk = 40;
    for (var at = 0; at < reply.length; at += chunk) {
      yield reply.substring(
        at,
        at + chunk > reply.length ? reply.length : at + chunk,
      );
    }
  }
}

const String wifiAsk = 'Hi I want to set up my wifi';
const String mailAsk = 'Can you automatically read my email and answer like me';

/// "set up my wifi": look first, then change it.
const String wifiPlanScript = '''
{"goal": "set up the Wi-Fi for the best speed and give guests their own network",
 "steps": [
   {"tool": "wifi_status", "args": {}, "description": "Look at the current Wi-Fi settings"},
   {"tool": "wifi_set", "args": {"band": "auto", "guest": true}, "description": "Switch Wi-Fi to the best speed and give guests their own network"}
 ],
 "questions": []}''';

/// The mail ask, answered with the three things it could do — a plan needs one
/// decision first.
const String mailNeedsScript = '''
{"goal": "read mail and answer like the user",
 "steps": [],
 "questions": [
   "read my mail and sort it",
   "draft replies in my style, you approve each",
   "send replies automatically"
 ]}''';

/// Picking the middle option: a drafts-only agent, saved on this device.
const String mailAgentScript = '''
{"goal": "save an agent that drafts replies to new mail in my style",
 "steps": [
   {"tool": "agent_create", "args": {"name": "Mail drafter", "goal": "draft replies to new mail in my style, never send", "tools": "mail_drafts"}, "description": "Save an agent that drafts replies to new mail in my style, for you to approve"}
 ],
 "questions": []}''';

/// Picking option 1: the hours counted from the usage log.
const String mailHoursScript = '''
{"goal": "run Mail drafter 9:00-18:00 on weekdays",
 "steps": [
   {"tool": "agent_schedule", "args": {"name": "Mail drafter", "hours": "9:00-18:00 on weekdays"}, "description": "Run Mail drafter 9:00-18:00 on weekdays"}
 ],
 "questions": []}''';
