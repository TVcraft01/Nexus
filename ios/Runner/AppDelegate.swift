import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // The eyes on iOS: Apple's Vision framework, answering the same channel
    // that ML Kit answers on Android. Registered here rather than through a pub
    // package because there is nothing to pull in — Vision is part of the
    // system, and the ML Kit pods (which is what the app used before) require
    // iOS 15.5, above the 15.0 this project targets.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "VisionBridge") {
      VisionBridge.register(with: registrar)
    }
  }
}
