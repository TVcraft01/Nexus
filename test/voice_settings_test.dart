// One language setting, two platform seams. A user who picks French in Voice
// Settings expects to be understood and answered in French; these tests prove
// the same tag reaches the recognizer and the speaker, and survives a restart.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/speech.dart';
import 'package:nexus/core/voice_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Input extends SpeechInput {
  final List<String> languages = <String>[];

  @override
  Future<void> setLanguage(String locale) async => languages.add(locale);
}

class _Output extends SpeechOutput {
  final List<String> languages = <String>[];

  @override
  Future<void> setLanguage(String locale) async => languages.add(locale);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Input input;
  late _Output output;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    input = _Input();
    output = _Output();
    SpeechInput.override = () => input;
    SpeechOutput.override = () => output;
  });

  tearDown(() {
    SpeechInput.override = null;
    SpeechOutput.override = null;
  });

  test('a language moves both halves of voice', () async {
    final VoiceSettings voice = VoiceSettings();

    await voice.setLanguage('fr-FR');

    expect(voice.language, 'fr-FR');
    expect(input.languages, <String>['fr-FR']);
    expect(output.languages, <String>['fr-FR']);
  });

  test('the choice is stored and applied on the next launch', () async {
    await VoiceSettings().setLanguage('de-DE');

    final VoiceSettings next = VoiceSettings();
    await next.attach();

    expect(next.language, 'de-DE');
    expect(input.languages.last, 'de-DE');
    expect(output.languages.last, 'de-DE');
  });

  test('an empty or unchanged tag does not touch the seams again', () async {
    final VoiceSettings voice = VoiceSettings(initial: 'en-US');

    await voice.setLanguage('en-US');
    await voice.setLanguage('  ');

    expect(voice.language, 'en-US');
    expect(input.languages, isEmpty);
    expect(output.languages, isEmpty);
  });

  test('Speak replies is on by default and survives a restart', () async {
    final VoiceSettings voice = VoiceSettings();
    await voice.attach();
    expect(voice.speakReplies, isTrue);

    voice.speakReplies = false;
    await Future<void>.delayed(Duration.zero);

    final VoiceSettings next = VoiceSettings();
    await next.attach();
    expect(next.speakReplies, isFalse);
  });

  test('the dropdown has a readable entry for the chosen tag', () {
    expect(VoiceSettings(initial: 'ja-JP').choice.label, '日本語');
    expect(VoiceSettings(initial: 'not-a-language').choice.tag, 'en-US');
  });
}
