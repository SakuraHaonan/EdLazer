import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var hapticsChannel: FlutterMethodChannel?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LazerHaptics") else { return }
    let channel = FlutterMethodChannel(name: "dev.naominet.lazer/haptics", binaryMessenger: registrar.messenger())
    hapticsChannel = channel
    channel.setMethodCallHandler { call, result in
      guard call.method == "impact" else { result(FlutterMethodNotImplemented); return }
      let args = call.arguments as? [String: Any] ?? [:]
      let intensity = max(0, min(1, (args["intensity"] as? NSNumber)?.doubleValue ?? 0.5))
      let kind = args["kind"] as? String ?? "tap"
      if intensity > 0 {
        // UIKit feedback generators are short-lived: build one per impact and
        // prime it right before firing. A generator kept for the life of the
        // app goes inert once iOS stops the haptic engine — a background trip
        // or an audio-session change is enough — and `impactOccurred` then
        // returns silently, without feedback and without an error, so the Dart
        // fallback never runs. Flutter's own HapticFeedback creates a
        // generator per call for the same reason.
        let style: UIImpactFeedbackGenerator.FeedbackStyle =
          kind == "boundary" ? .medium : kind == "detent" ? .rigid : .light
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred(intensity: CGFloat(intensity))
      }
      result(nil)
    }
  }
}
