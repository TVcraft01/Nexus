// The eyes: Google's ML Kit, on this phone, with no network in the loop.
//
// Two models run over the attached picture, one after the other:
//
//   * text recognition (OCR) reads the words in it — a sign, a page, a label;
//   * image labeling names what is in it — "Dog", "Outdoor", "Car".
//
// Their answers are folded into one bracketed sentence, and that sentence is
// what the local brain is asked. The model never receives the picture itself:
// the text it runs on this phone is a text model, and handing it an image would
// be either an unsupported call or an invented description. What it receives
// here is evidence the phone actually gathered, which is the difference between
// a sighting and a guess.
//
// Everything is behind [VisionAiService], so the thread, the live page and the
// attachment flow do not change. The two model calls and the brain are
// constructor seams: a test drives the formatting and the fallback without a
// camera, a lens, or a platform channel.
//
// A failure is a sentence, never a throw. The service is answering a bubble:
// a missing model file, a refused permission, or a brain that is not running
// all have to leave something readable on screen.
import 'dart:convert' show jsonDecode;

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugPrint, defaultTargetPlatform, kIsWeb;
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'attachments.dart' show kPhotoPrompt, kScreenshotPrompt;
import 'local_ai_service.dart';
import 'ollama_service.dart' show OllamaException, OllamaService;
import 'on_device_ai_service.dart' show OnDeviceAiService;
import 'vision_ai.dart';

/// How many labels are handed to the brain. The top few are the ones a person
/// would name first; a list of twenty is noise the model has to filter itself.
const int kMlVisionLabelLimit = 5;

/// How many labels each picture contributes to a multi-image turn.
///
/// Fewer than [kMlVisionLabelLimit] on purpose: with three pictures the prompt
/// is three short lists plus a question, and three names are enough for the
/// model to tell the pictures apart. The OCR pass is skipped entirely for a
/// multi-image turn — concatenated OCR from several screenshots is what made a
/// two-photo answer read as one garbled wall of text on the A25.
const int kMlVisionMultiLabelLimit = 3;

/// Reads the text in an image and answers it, or an empty string.
typedef ImageTextReader = Future<String> Function(String path);

/// Names the objects in an image, best first.
typedef ImageLabelReader = Future<List<String>> Function(String path);

/// What the service says when the models worked but the brain did not.
const String kMlVisionBrainFailedText =
    'I could read the image, but the AI could not answer about it just now.';

/// The system turn for a vision answer.
///
/// Deliberately *not* the chat system turn: that one offers the phone-action
/// vocabulary, and a small model given a picture question can answer with
/// `{"action":"get_time"}` instead of a sentence. The eyes already did the
/// looking; this turn only has to turn the evidence into words, so it is told
/// to do exactly that and nothing else.
const String kNexusVisionSystem =
    'You are Nexus, looking at a photo on this device. The OCR text and object '
    'labels are observations from the phone. Describe the photo in one or two '
    'short sentences, quoting any visible text exactly. STRICT RULE: If the '
    "user asks what the text says, you MUST repeat the 'OCR Text:' exactly as "
    'provided. Do not make up an answer. Do not use outside knowledge. Do not '
    'explain or define the words. Do not talk about the date or time. Never '
    "say 'The user has uploaded'. Answer directly: describe the picture, and "
    'never call it an upload. Never output JSON, actions, or key-value records.';

/// ML Kit's on-device text recognition and image labeling, plus the local brain.
class MlVisionService implements VisionAiService {
  MlVisionService({
    ImageTextReader? readText,
    ImageLabelReader? readLabels,
    Future<String> Function(String prompt)? answer,
  }) {
    _readText = readText;
    _readLabels = readLabels;
    _answer = answer;
  }

  /// Test seams. Null runs the real ML Kit model / the app's local brain.
  late final ImageTextReader? _readText;
  late final ImageLabelReader? _readLabels;
  late final Future<String> Function(String prompt)? _answer;

  /// ML Kit's models ship for Android and iOS. A desktop build has no eyes, and
  /// says so through the same [available] the rest of the app already reads.
  @override
  bool get available =>
      _readText != null ||
      _readLabels != null ||
      (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS));

  /// Looks at [imagePath] and answers [question] with what was found.
  ///
  /// Both model calls are attempted together; one failing does not throw away
  /// what the other saw. When neither finds anything, the turn keeps the
  /// bracketed placeholder it already had — no invented description.
  ///
  /// The detection is reported through [onEvidence] before the brain is asked,
  /// so the bubble can show it immediately.
  @override
  Future<String> describe(
    String imagePath, {
    String question = '',
    VisionEvidenceCallback? onEvidence,
  }) async {
    final List<Object> found = await Future.wait(<Future<Object>>[
      _textOrEmpty(imagePath),
      _labelsOrEmpty(imagePath),
    ]);
    final String text = (found[0] as String).trim();
    final List<String> labels = found[1] as List<String>;

    // The eyes are done. Hand the detection over now, before the brain is
    // asked: the bubble can show what was scanned while the answer is still
    // being written, and a model that answers badly cannot hide the fact that
    // OCR and labeling succeeded.
    try {
      onEvidence?.call(VisionEvidence(text: text, labels: labels));
    } catch (error) {
      // A drawing callback that fails is not a reason to lose the answer.
      debugPrint('VISION: the evidence callback failed ($error)');
    }

    if (text.isEmpty && labels.isEmpty) {
      // The same annotation the attachment already carries. A screenshot keeps
      // its own noun; everything else is the photo placeholder.
      return question.startsWith('[User attached') ? question : kPhotoPrompt;
    }

    final String objects = labels.isEmpty ? 'none' : labels.join(', ');
    final String ocr = text.isEmpty ? 'none' : text;
    // Evidence first, question second, in two labelled lines. A small model
    // reads the first line as context and the second as the thing to answer;
    // the old bracketed sentence put the question inside the same clause as
    // the evidence, and the model answered "The user has uploaded an image…"
    // instead of the question. The labels are the prompt's grammar now.
    final String context =
        '[Image Context: Text="$ocr", Objects="$objects"]\n'
        '[User Question]: $question';

    try {
      final String answer = await (_answer ?? _askLocalBrain)(context);
      debugPrint(
        'VISION: text=${text.length} labels=${labels.length} '
        'answer=${answer.trim().length}',
      );
      final String plain = _plainAnswer(answer, text: text, labels: labels);
      // The prompt rule is not enough for a 0.5B model: measured on the A25 it
      // answered "a red sign" when asked what the sign said. If the question is
      // about the words and the answer does not actually contain them, the
      // evidence is the only honest answer left.
      if (text.isNotEmpty &&
          _asksForText(question) &&
          !_mentions(plain, text)) {
        return 'The text says: "$text"';
      }
      return plain;
    } on OllamaException catch (error) {
      return error.message;
    } catch (error) {
      debugPrint('VISION: the local brain failed ($error)');
      return kMlVisionBrainFailedText;
    }
  }

  /// Answers a turn that carries several pictures from their object labels.
  ///
  /// One brain call, not one per image: the pictures share the question, so a
  /// single prompt naming each image is the shape the model can actually
  /// reason about. Each picture contributes at most [kMlVisionMultiLabelLimit]
  /// labels and no OCR text:
  ///
  ///     [Image 1: Sky, Space] [Image 2: Dog, Couch]
  ///     [User Question]: what do you see?
  ///
  /// Evidence is still reported per picture before the brain is asked, so the
  /// bubbles show what ML Kit saw even if the answer is weak. A picture with
  /// no labels contributes `no objects`, which keeps the numbering honest.
  @override
  Future<String> describeMany(
    List<String> imagePaths, {
    String question = '',
    void Function(int index, VisionEvidence evidence)? onEvidence,
  }) async {
    if (imagePaths.length < 2) {
      return describe(
        imagePaths.isEmpty ? '' : imagePaths.first,
        question: question,
        onEvidence: (VisionEvidence evidence) => onEvidence?.call(0, evidence),
      );
    }
    final List<List<String>> labelsByImage = <List<String>>[];
    for (int i = 0; i < imagePaths.length; i++) {
      final List<String> labels = await _labelsOrEmpty(imagePaths[i]);
      // The bubble shows everything the labeler found; the prompt gets the top
      // three, because five names times three pictures is a list the model has
      // to filter before it can answer.
      labelsByImage.add(
        labels.take(kMlVisionMultiLabelLimit).toList(growable: false),
      );
      try {
        onEvidence?.call(i, VisionEvidence(labels: labels));
      } catch (error) {
        debugPrint('VISION: the evidence callback failed ($error)');
      }
    }
    final bool anyLabels = labelsByImage.any(
      (List<String> labels) => labels.isNotEmpty,
    );
    if (!anyLabels) {
      return question.startsWith('[User attached') ? question : kPhotoPrompt;
    }
    final String context =
        '${<String>[for (int i = 0; i < labelsByImage.length; i++) '[Image ${i + 1}: '
              '${labelsByImage[i].isEmpty ? 'no objects' : labelsByImage[i].join(', ')}]'].join(' ')}\n'
        '[User Question]: $question';
    try {
      final String answer = await (_answer ?? _askLocalBrain)(context);
      debugPrint(
        'VISION: images=${imagePaths.length} '
        'labels=${labelsByImage.fold<int>(0, (int n, List<String> l) => n + l.length)} '
        'answer=${answer.trim().length}',
      );
      return _plainAnswer(
        answer,
        text: '',
        labels: <String>[
          for (final List<String> labels in labelsByImage) ...labels,
        ],
      );
    } on OllamaException catch (error) {
      return error.message;
    } catch (error) {
      debugPrint('VISION: the local brain failed ($error)');
      return kMlVisionBrainFailedText;
    }
  }

  /// Whether [question] asks what the words in the picture say.
  ///
  /// Narrow on purpose: this is the one question the model must answer from
  /// OCR, and a broad pattern would replace an ordinary description with the
  /// raw text. The same words as the strict system rule, in the shell's hands.
  static bool _asksForText(String question) {
    final String said = question
        .toLowerCase()
        .replaceAll(RegExp(r"[^a-z0-9\s]"), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (said.isEmpty) return false;
    return RegExp(
      r'^(?:what (?:does|do) (?:it|this|that|the (?:text|sign|label|note|'
      r'screen|image|words?)) say'
      r'|whats? (?:is )?written'
      r'|read (?:it|this|that|the (?:text|sign|label|note|screen|image))'
      r'|can you read (?:it|this|that|the text))',
    ).hasMatch(said);
  }

  /// Whether [answer] repeats [evidence], ignoring case and whitespace.
  ///
  /// OCR often arrives with line breaks the model rewrites as spaces, so an
  /// exact string comparison would reject an answer that is faithfully quoting
  /// the text. Normalising both sides is what makes the check about the words.
  static bool _mentions(String answer, String evidence) {
    String normalised(String value) =>
        value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
    final String wanted = normalised(evidence);
    return wanted.isNotEmpty && normalised(answer).contains(wanted);
  }

  /// Turns a brain answer into something a bubble can show.
  ///
  /// The local brain is the chat model, and that model is also offered the
  /// phone-action vocabulary. A small model asked a vision question can answer
  /// with the wire format instead of a sentence — measured on the A25 as
  /// `{"action":"get_time"}` — and that object is not an answer about the
  /// picture. When that happens the evidence the phone actually gathered is the
  /// honest thing left to say. A normal sentence is passed through untouched.
  String _plainAnswer(
    String answer, {
    required String text,
    required List<String> labels,
  }) {
    final String trimmed = answer.trim();
    if (trimmed.isEmpty) return kMlVisionBrainFailedText;
    if (RegExp(r'\{\s*"action"\s*:').hasMatch(trimmed)) {
      return _evidenceSentence(text: text, labels: labels);
    }
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      // A JSON answer that is not a sentence. Read the answer field when there
      // is one, so `{"result": "a dog"}` still reaches the user; otherwise
      // fall back to the evidence rather than show wire format.
      final Object? decoded = _decode(trimmed);
      final String? field = _answerField(decoded);
      if (field != null && field.isNotEmpty) return field;
      return _evidenceSentence(text: text, labels: labels);
    }
    return trimmed;
  }

  static Object? _decode(String text) {
    try {
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }

  static String? _answerField(Object? decoded) {
    if (decoded is! Map) return null;
    for (final String key in const <String>[
      'result',
      'answer',
      'text',
      'response',
    ]) {
      final Object? value = decoded[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
      if (value is num || value is bool) return value.toString();
    }
    return null;
  }

  /// What the phone saw, in a sentence — the fallback when the brain's answer
  /// was not about the picture. This is evidence, not invention: every word
  /// here came from OCR or a label.
  static String _evidenceSentence({
    required String text,
    required List<String> labels,
  }) {
    final List<String> parts = <String>[];
    if (labels.isNotEmpty) {
      parts.add('In the image I can see ${labels.join(', ')}.');
    }
    final String words = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (words.isNotEmpty) {
      final String shown = words.length <= 240
          ? words
          : '${words.substring(0, 240)}…';
      parts.add('The text reads "$shown".');
    }
    return parts.isEmpty ? kMlVisionBrainFailedText : parts.join(' ');
  }

  /// The vision brain, memoised so the weights are loaded once per process.
  ///
  /// On-device first, the PC second — the same trust order as the chat chain,
  /// but with [kNexusVisionSystem] as the system turn. Its own instance rather
  /// than [LocalAiService.current] because the chat chain's system prompt
  /// offers actions, and answering a picture with an action is the failure this
  /// separation exists to prevent.
  static LocalAiService? _visionBrain;

  static LocalAiService get _defaultVisionBrain =>
      _visionBrain ??= FallbackAiService(
        onDevice: OnDeviceAiService(
          system: kNexusVisionSystem,
          includeClock: false,
          includeMemory: false,
        ),
        pc: const OllamaService(
          system: kNexusVisionSystem,
          includeClock: false,
          includeMemory: false,
        ),
      );

  /// Sends the gathered evidence to a local brain. A test's override wins over
  /// the app's memoised chain, which is what keeps the vision seam mockable.
  static Future<String> _askLocalBrain(String prompt) =>
      (LocalAiService.override?.call() ?? _defaultVisionBrain).generateResponse(
        prompt,
      );

  Future<String> _textOrEmpty(String path) async {
    try {
      return await (_readText ?? _recognizeText)(path);
    } catch (error) {
      // A missing model or a permission is not a question the user can answer
      // from a bubble; the labels below may still describe the picture.
      return '';
    }
  }

  Future<List<String>> _labelsOrEmpty(String path) async {
    try {
      final List<String> labels = await (_readLabels ?? _labelImage)(path);
      final List<String> unique = <String>[];
      final Set<String> seen = <String>{};
      for (final String label in labels) {
        final String trimmed = label.trim();
        if (trimmed.isEmpty || !seen.add(trimmed.toLowerCase())) continue;
        unique.add(trimmed);
        if (unique.length == kMlVisionLabelLimit) break;
      }
      return unique;
    } catch (error) {
      return const <String>[];
    }
  }

  /// The real OCR pass. The recognizer is closed even when the image cannot be
  /// read, because an open one holds a model file until the app is killed.
  static Future<String> _recognizeText(String path) async {
    // Latin is the default script; a phone in another script still gets the
    // base recognizer, which is the one this package ships on Android.
    final TextRecognizer recognizer = TextRecognizer();
    try {
      final RecognizedText recognized = await recognizer.processImage(
        InputImage.fromFilePath(path),
      );
      return recognized.text;
    } finally {
      await recognizer.close();
    }
  }

  /// The real labeling pass, best label first and cut to
  /// [kMlVisionLabelLimit].
  static Future<List<String>> _labelImage(String path) async {
    // The default 0.5 confidence floor: below it ML Kit is guessing, and a
    // guess in the prompt is worse than one fewer object.
    final ImageLabeler labeler = ImageLabeler(options: ImageLabelerOptions());
    try {
      final List<ImageLabel> found = await labeler.processImage(
        InputImage.fromFilePath(path),
      );
      found.sort(
        (ImageLabel a, ImageLabel b) => b.confidence.compareTo(a.confidence),
      );
      return found
          .take(kMlVisionLabelLimit)
          .map((ImageLabel label) => label.label)
          .toList();
    } finally {
      await labeler.close();
    }
  }
}

/// The two placeholders, exposed so the fallback above can be asserted without
/// importing the whole attachment layer into a test.
const List<String> kMlVisionPlaceholders = <String>[
  kPhotoPrompt,
  kScreenshotPrompt,
];
