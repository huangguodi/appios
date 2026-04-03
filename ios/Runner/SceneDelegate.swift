import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    registerMihomoPluginIfNeeded()
    DispatchQueue.main.async { [weak self] in
      self?.registerMihomoPluginIfNeeded()
    }
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    registerMihomoPluginIfNeeded()
  }

  private func registerMihomoPluginIfNeeded() {
    if let controller = window?.rootViewController as? FlutterViewController {
      MihomoIosPlugin.shared.register(with: controller)
    }
  }
}
