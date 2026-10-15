import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var hapticsChannel: FlutterMethodChannel?
  private let tapImpact = UIImpactFeedbackGenerator(style: .light)
  private let seekImpact = UIImpactFeedbackGenerator(style: .rigid)
  private let boundaryImpact = UIImpactFeedbackGenerator(style: .medium)
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
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "impact" else { result(FlutterMethodNotImplemented); return }
      guard let self = self else { result(nil); return }
      let args = call.arguments as? [String: Any] ?? [:]
      let intensity = max(0, min(1, (args["intensity"] as? NSNumber)?.doubleValue ?? 0.5))
      let kind = args["kind"] as? String ?? "tap"
      let generator = kind == "boundary" ? self.boundaryImpact : kind == "detent" ? self.seekImpact : self.tapImpact
      generator.prepare()
      generator.impactOccurred(intensity: CGFloat(intensity))
      result(nil)
    }
  }
}
