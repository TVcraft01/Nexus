// The user's standing instruction is a preference, not a chat line: it has to
// survive a cleared conversation, be gone when blanked, and never grow into an
// essay that crowds the question out of a small model's context.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/system_prompt.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SystemPrompt.debugReset();
  });

  tearDown(SystemPrompt.debugReset);

  test('a blank field adds nothing to the system turn', () async {
    final SystemPrompt prompt = SystemPrompt();
    await prompt.attach();
    expect(prompt.context, isEmpty);
  });

  test('the instruction survives a restart', () async {
    await SystemPrompt().setText('The user is TVCraft. Answer in French.');

    final SystemPrompt next = SystemPrompt();
    await next.attach();

    expect(next.text, 'The user is TVCraft. Answer in French.');
    expect(next.context, 'The user is TVCraft. Answer in French.');
  });

  test('blanking the field removes the stored instruction', () async {
    final SystemPrompt prompt = SystemPrompt();
    await prompt.setText('Temporary rule');
    await prompt.clear();

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prompt.text, isEmpty);
    expect(prefs.getString(SystemPrompt.key), isNull);
  });

  test('a long paste is cut to the limit rather than kept whole', () async {
    final SystemPrompt prompt = SystemPrompt();
    await prompt.setText('x' * (kSystemPromptLimit + 50));

    expect(prompt.text.length, kSystemPromptLimit);
  });
}
