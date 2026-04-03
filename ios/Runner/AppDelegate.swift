import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let ok = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    registerMihomoPluginIfNeeded()
    DispatchQueue.main.async { [weak self] in
      self?.registerMihomoPluginIfNeeded()
    }
    return ok
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

  func registerMihomoPluginIfNeeded() {
    if let controller = window?.rootViewController as? FlutterViewController {
      MihomoIosPlugin.shared.register(with: controller)
    }
  }
}
