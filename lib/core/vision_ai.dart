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

/// Something that can look at an image and answer a question about it.
///
/// Deliberately one method: this is the whole contract a sighted implementation
/// has to keep. It answers a sentence rather than throwing, because every
/// caller is drawing a bubble — an exception would reach the user as a red
/// notice about a bug, when the honest thing to say is what went wrong.
abstract class VisionAiService {
  /// Test seam, in the shape of [ChatLog.override] and [AttachmentStore.override]:
  /// a test states its own service instead of touching a platform. The app
  /// never sets it.
  static VisionAiService Function()? override;

  /// The service this build uses: whatever a test installed, else no eyes.
  static VisionAiService get current =>
      override?.call() ?? const MissingVisionAi();

  /// Whether this build can look at images at all.
  bool get available;

  /// What [imagePath] shows, in answer to [question].
  ///
  /// Answers a sentence, never throws: a sighted service that fails still owes
  /// the thread something it can draw, and the honest failure is a sentence.
  Future<String> describe(String imagePath, {String question = ''});
}

/// The shipped service: no vision module is installed, and it says so.
///
/// [available] false is the fact the shell branches on when it wants to tell
/// the user before they ask; [describe] is the answer for when they ask anyway.
class MissingVisionAi implements VisionAiService {
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
  Future<String> describe(String imagePath, {String question = ''}) async =>
      kNexusVisionMissingText;
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
