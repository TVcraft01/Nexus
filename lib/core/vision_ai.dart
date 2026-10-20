// The eyes this app does not have yet.
//
// Every brain this build runs is a text model. A picture attached to the
// conversation used to be handed to one of them as a bracketed sentence
// (`[User attached a photo]`), and a text model asked "what is this?" answers
// that annotation with an invented description. The user cannot tell an
// invention from a sighting, which makes an invented description worse than an
// honest refusal: one of them is a lie the app tells about a photograph.
//
// So a picture never goes to a text brain. It goes to [VisionAiService], the
// seam that will hold the eyes. The shipped implementation is
// [MissingVisionAi]: it has no eyes, and it says so in one sentence. The day a
// real one exists — a phone model with an image encoder, or a PC's vision
// endpoint over the mesh — it is installed behind the same interface, and the
// thread, the live page and the attachment flow do not change.
library;

/// What the app says while it has no vision module.
///
/// One sentence, in one place: it names what the user did (attached a photo),
/// and it names the truth (there is no vision module), so the next question —
/// "can I fix that?" — has an answer that is not a guess.
const String kNexusVisionMissingText =
    'I can see you attached a photo, but my vision module is not installed '
    'yet.';

/// What the eyes actually found in a picture.
///
/// This is evidence, not a description: [text] is the OCR pass's own string and
/// [labels] are ML Kit's own object names. It exists separately from the answer
/// so the bubble can show what the phone saw even when the small language model
/// answers badly — the user should never have to trust the model to know that
/// the scan ran.
class VisionEvidence {
  const VisionEvidence({this.text = '', this.labels = const <String>[]});

  /// The words ML Kit read, exactly as it read them. May contain newlines.
  final String text;

  /// The object names, best first. Empty when the labeler found nothing.
  final List<String> labels;

  /// True when there is nothing worth drawing under the picture.
  bool get isEmpty => text.trim().isEmpty && labels.isEmpty;
}

/// Told what the eyes found, before the brain is asked to answer.
///
/// A callback rather than a second scan: ML Kit is the slow part, and running
/// it once for the caption and again for the answer would be two reads of the
/// same pixels. A caller that only wants the sentence ignores it.
typedef VisionEvidenceCallback = void Function(VisionEvidence evidence);

/// Something that can look at an image and answer a question about it.
///
/// Deliberately one method: this is the whole contract a sighted implementation
/// has to keep. It answers a sentence rather than throwing, because every
/// caller is drawing a bubble — an exception would reach the user as a red
/// notice about a bug, when the honest thing to say is what went wrong.
abstract class VisionAiService {
  const VisionAiService();

  /// Test seam, in the shape of [ChatLog.override] and [AttachmentStore.override]:
  /// a test states its own service instead of touching a platform. The app
  /// never sets it.
  static VisionAiService Function()? override;

  /// The service the app installs at startup — [MlVisionService] on a phone.
  ///
  /// A factory rather than an instance so the models are not built before the
  /// first picture; and separate from [override] so a widget test that states
  /// its own service never has to know what production installed.
  static VisionAiService Function()? defaultFactory;

  /// The service this build uses: whatever a test installed, else what the app
  /// installed, else no eyes.
  static VisionAiService get current =>
      override?.call() ?? defaultFactory?.call() ?? const MissingVisionAi();

  /// Whether this build can look at images at all.
  bool get available;

  /// What [imagePath] shows, in answer to [question].
  ///
  /// Answers a sentence, never throws: a sighted service that fails still owes
  /// the thread something it can draw, and the honest failure is a sentence.
  ///
  /// [onEvidence] is called with the OCR text and labels as soon as the eyes
  /// have finished, before the brain is asked. It is how the bubble can show
  /// the detection without waiting for an answer, and without a second scan.
  Future<String> describe(
    String imagePath, {
    String question = '',
    VisionEvidenceCallback? onEvidence,
  });

  /// What a turn carrying several pictures shows, in answer to [question].
  ///
  /// The default is one [describe] per picture and the first real answer, which
  /// is what every implementation got for free before this method existed.
  /// [MlVisionService] overrides it because asking the brain once per image
  /// means the last answer is chosen by iteration order, and because a handful
  /// of images cannot share one prompt without a batch shape.
  ///
  /// [onEvidence] receives each picture's evidence with the index it belongs
  /// to, so a caller can draw it under the right bubble.
  Future<String> describeMany(
    List<String> imagePaths, {
    String question = '',
    void Function(int index, VisionEvidence evidence)? onEvidence,
  }) async {
    String answer = '';
    for (int i = 0; i < imagePaths.length; i++) {
      final String next = await describe(
        imagePaths[i],
        question: question,
        onEvidence: (VisionEvidence evidence) => onEvidence?.call(i, evidence),
      );
      if (answer.trim().isEmpty && next.trim().isNotEmpty) answer = next;
    }
    return answer;
  }
}

/// The shipped service: no vision module is installed, and it says so.
///
/// [available] false is the fact the shell branches on when it wants to tell
/// the user before they ask; [describe] is the answer for when they ask anyway.
class MissingVisionAi extends VisionAiService {
  const MissingVisionAi();

  /// No eyes at all.
  @override
  bool get available => false;

  /// [kNexusVisionMissingText], whatever the picture or the question.
  ///
  /// The arguments are accepted and ignored on purpose: the interface is the
  /// one a sighted implementation will need, and a caller that has to special
  /// case the missing one would have two code paths to keep in step.
  @override
  Future<String> describe(
    String imagePath, {
    String question = '',
    VisionEvidenceCallback? onEvidence,
  }) async => kNexusVisionMissingText;
}

/// Whether [text] asks about the picture, rather than about the world.
///
/// Narrow on purpose. "What is this?" after a photo means the photo; "what is
/// this app?" means Nexus, and answering that with the vision notice would be
/// the shell refusing a question nobody asked it. So each pattern is anchored
/// to the whole sentence, and the phrasings are the ones that have nothing to
/// say without a picture: this/that, what you can see, and "describe this".
bool isVisionQuestion(String text) {
  final String said = text
      .toLowerCase()
      .replaceAll(RegExp("[’']"), '')
      .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (said.isEmpty) return false;
  const String picture = r'(?:photo|picture|image|screenshot)';
  final List<RegExp> patterns = <RegExp>[
    RegExp('^(?:what is|whats) (?:this|that)(?: $picture)?\$'),
    RegExp('^what (?:can|could) you see(?: in (?:this|the) $picture)?\$'),
    RegExp('^what do you see(?: in (?:this|the) $picture)?\$'),
    RegExp(
      '^(?:describe|read|look at) (?:this|that|the|it)'
      '(?: $picture)?\$',
    ),
    RegExp('^what (?:is|are) (?:in|on) (?:this|the) $picture\$'),
    RegExp('^whats (?:in|on) (?:this|the) $picture\$'),
  ];
  return patterns.any((RegExp pattern) => pattern.hasMatch(said));
}
