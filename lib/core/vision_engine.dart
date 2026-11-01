// The eyes, behind one interface, on both phones.
//
// Nexus looks at a picture twice: once to read the words in it, once to name
// the objects. That work used to be two Google ML Kit Dart packages, which tied
// the whole app to Android and to iOS 15.5. The target device here is an iPhone
// 6s on iOS 15.0.2, so the engine moved behind this one interface:
//
//   * Android answers with ML Kit, natively, at the same versions the Dart
//     packages pinned (text-recognition 16.0.1, image-labeling 17.0.9). Nothing
//     the phone does changes.
//   * iOS answers with Apple's own Vision framework — VNRecognizeTextRequest
//     and VNClassifyImageRequest. No pod, no third-party model, and no floor
//     above the 15.0 this project targets.
//
// Both are reached the same way: one method channel, two methods, a path in and
// plain data out. The channel is deliberately dumb — it moves a path and a
// result, and knows nothing about prompts, limits or fallbacks. Those stay in
// [MlVisionService] where they are already tested.
//
// A build with no handler at all (the desktop shells) throws
// [VisionUnavailable] instead of a raw [MissingPluginException]. Callers in this
// app already treat a failure as a sentence or an empty finding, so nothing
// crashes on a platform without eyes — but the type is honest about what
// happened, which a `MissingPluginException` from an unrelated channel is not.
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;

/// The channel every platform implementation of [VisionEngine] listens on.
const String kVisionChannelName = 'dev.nexus.nexus/vision';

/// Something that can read the text in a picture and name what is in it.
///
/// One path in, plain data out. Implementations are not expected to trim,
/// de-duplicate or cap: [MlVisionService] owns those decisions so that Android
/// and iOS cannot drift apart on them.
abstract class VisionEngine {
  /// Test seam, in the shape of [VisionAiService.override] and
  /// `ChatLog.override`: a test states its own engine instead of touching a
  /// platform channel. The app never sets it.
  static VisionEngine? override;

  /// The engine this build uses: whatever a test installed, else the real
  /// platform channel, else none.
  ///
  /// Computed on every read rather than memoised, so a test that sets
  /// [override] and later clears it gets the platform back. The engine itself
  /// is a `const` with no state worth keeping.
  static VisionEngine? get current =>
      override ?? (_platformSupported ? const PlatformVisionEngine() : null);

  /// True when this build has a platform that could answer.
  ///
  /// A fact about the platform, not a probe: asking a channel whether it exists
  /// would cost a round trip to answer a question the app already knows. The
  /// desktop shells have no implementation, so they say no here.
  static bool get isSupported => override != null || _platformSupported;

  static bool get _platformSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// The words in the picture at [path], newlines preserved.
  ///
  /// Throws [VisionUnavailable] when there is no engine, and [VisionFailed]
  /// when the engine ran but could not read this file.
  Future<String> recognizeText(String path);

  /// The objects in the picture at [path], best match first.
  ///
  /// Same two failures as [recognizeText]. An empty list means the engine ran
  /// and found nothing, which is a different thing from having no engine.
  Future<List<String>> labelObjects(String path);
}

/// No engine on this platform — the desktop shells, or a test that installed
/// nothing on a build where the channel has no handler.
class VisionUnavailable implements Exception {
  const VisionUnavailable([this.reason = 'no vision engine on this platform']);

  final String reason;

  @override
  String toString() => 'VisionUnavailable: $reason';
}

/// The engine was there but could not read this particular picture.
class VisionFailed implements Exception {
  const VisionFailed(this.message);

  final String message;

  @override
  String toString() => 'VisionFailed: $message';
}

/// The real engine: a method channel answered by Kotlin on Android and Swift on
/// iOS.
///
/// The two methods are the whole contract:
///
///   `recognizeText(path)` returns `String`
///   `labelObjects(path)` returns a list of maps, each with a `label` string
///   and a `confidence` number
///
/// Scores are carried on the wire rather than dropped at the boundary, because
/// ML Kit and Vision do not use the same scale and each side is the only one
/// that can sort its own results sensibly. The order on the wire is already
/// best-first; the scores are there so a caller can apply a floor without a
/// second round trip.
class PlatformVisionEngine implements VisionEngine {
  const PlatformVisionEngine();

  static const MethodChannel channel = MethodChannel(kVisionChannelName);

  @override
  Future<String> recognizeText(String path) async {
    final String? text = await _invoke<String>('recognizeText', path);
    return text ?? '';
  }

  @override
  Future<List<String>> labelObjects(String path) async {
    final List<Object?>? raw = await _invoke<List<Object?>>('labelObjects', path);
    if (raw == null) return const <String>[];
    final List<String> labels = <String>[];
    for (final Object? entry in raw) {
      if (entry is Map) {
        final Object? label = entry['label'];
        if (label is String && label.trim().isNotEmpty) labels.add(label.trim());
      } else if (entry is String && entry.trim().isNotEmpty) {
        // Tolerated so a simpler platform side is not a breaking change: the
        // contract allows bare strings, and reading them costs one branch.
        labels.add(entry.trim());
      }
    }
    return labels;
  }

  /// One call, with the three failures folded into the two types above.
  ///
  /// [MissingPluginException] is the important one: it is what a platform with
  /// no handler throws, and it must not reach a bubble as a crash. It is also
  /// what a `dart test` run on Linux throws, which is why the tests can assert
  /// this path without a phone.
  Future<T?> _invoke<T>(String method, String path) async {
    try {
      return await channel.invokeMethod<T>(method, <String, Object?>{'path': path});
    } on MissingPluginException catch (error) {
      throw VisionUnavailable('$method: no handler ($error)');
    } on PlatformException catch (error) {
      throw VisionFailed(
        error.message ?? '${error.code}: $method failed',
      );
    }
  }
}
