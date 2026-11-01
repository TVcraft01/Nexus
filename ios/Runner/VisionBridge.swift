import Flutter
import UIKit
import Vision

/// The eyes on iOS: Apple's Vision framework, not ML Kit.
///
/// The Android half of this channel is answered by ML Kit (VisionBridge.kt).
/// Here it is `VNRecognizeTextRequest` and `VNClassifyImageRequest`, which are
/// part of iOS itself. That is the point: the ML Kit pods require iOS 15.5, and
/// Nexus has to run on an iPhone 6s on iOS 15.0.2. Vision has been in the system
/// since iOS 13, needs no pod, downloads no model, and ships no new deployment
/// floor.
///
/// The channel is deliberately thin — a path in, the framework's own answer out.
/// Trimming, de-duplication and the cut to five labels all live in
/// lib/core/ml_vision_service.dart, where both platforms share them.
///
/// Must match kVisionChannelName in lib/core/vision_engine.dart.
final class VisionBridge: NSObject, FlutterPlugin {
  static let channelName = "dev.nexus.nexus/vision"

  /// The confidence floor the Android side uses. Below it the classifier is
  /// guessing, and a guess in the prompt is worse than one fewer object.
  private static let minLabelConfidence: Float = 0.5

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(VisionBridge(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let arguments = call.arguments as? [String: Any],
      let path = arguments["path"] as? String,
      !path.isEmpty
    else {
      result(FlutterError(
        code: "NO_PATH",
        message: "No image path was provided",
        details: nil
      ))
      return
    }

    // Vision is synchronous and CPU-bound. Off the main thread, so a large
    // photo cannot stall the frame that is drawing the bubble it belongs to.
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        switch call.method {
        case "recognizeText":
          let text = try Self.recognizeText(path: path)
          DispatchQueue.main.async { result(text) }
        case "labelObjects":
          let labels = try Self.labelObjects(path: path)
          DispatchQueue.main.async { result(labels) }
        default:
          DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
        }
      } catch {
        let message = error.localizedDescription
        DispatchQueue.main.async {
          result(FlutterError(
            code: call.method == "recognizeText" ? "OCR_FAILED" : "LABEL_FAILED",
            message: message,
            details: nil
          ))
        }
      }
    }
  }

  // MARK: - The two passes

  /// The words in the picture, newlines preserved.
  ///
  /// `.accurate` rather than `.fast`: the result is quoted to the person, and a
  /// wrong character in a sign or a label is worse than a short wait. Language
  /// correction is on for the same reason — it fixes the common OCR slips in
  /// ordinary prose without changing what the picture says.
  private static func recognizeText(path: String) throws -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true

    let handler = VNImageRequestHandler(
      url: URL(fileURLWithPath: path),
      options: [:]
    )
    try handler.perform([request])

    let observations = request.results ?? []
    return observations
      .compactMap { $0.topCandidates(1).first?.string }
      .joined(separator: "\n")
  }

  /// The objects in the picture, best match first.
  ///
  /// Vision's identifiers arrive lowercase ("dog", "outdoor") while ML Kit's
  /// arrive capitalised ("Dog", "Outdoor"), and the same sentence is built from
  /// them on both platforms. Capitalising here keeps the sentence identical
  /// whichever phone produced it, instead of leaking the framework into the copy.
  private static func labelObjects(path: String) throws -> [[String: Any]] {
    let request = VNClassifyImageRequest()

    let handler = VNImageRequestHandler(
      url: URL(fileURLWithPath: path),
      options: [:]
    )
    try handler.perform([request])

    let observations = (request.results ?? [])
      .filter { $0.confidence >= minLabelConfidence }
      .sorted { $0.confidence > $1.confidence }

    return observations.map { observation in
      [
        "label": observation.identifier.prefix(1).uppercased()
          + observation.identifier.dropFirst(),
        "confidence": Double(observation.confidence),
      ]
    }
  }
}
