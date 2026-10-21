import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  private var privacyOverlay: AppPrivacyOverlay?

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    if let windowScene = scene as? UIWindowScene {
      privacyOverlay = AppPrivacyOverlay(windows: { [weak windowScene] in
        windowScene?.windows ?? []
      })
      if scene.activationState != .foregroundActive {
        privacyOverlay?.show()
      }
    }
    IncomingUriChannelBridge.shared.handle(
      urlContexts: connectionOptions.urlContexts
    )
    for userActivity in connectionOptions.userActivities {
      _ = IncomingUriChannelBridge.shared.handle(userActivity: userActivity)
    }
  }

  override func sceneWillResignActive(_ scene: UIScene) {
    privacyOverlay?.show()
    super.sceneWillResignActive(scene)
  }

  override func sceneDidEnterBackground(_ scene: UIScene) {
    // Re-enumerate windows: a sheet or keyboard window may have appeared
    // since willResignActive. UIKit takes its snapshot after this callback.
    privacyOverlay?.show()
    super.sceneDidEnterBackground(scene)
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    privacyOverlay?.hide()
  }

  override func sceneDidDisconnect(_ scene: UIScene) {
    privacyOverlay?.hide()
    privacyOverlay = nil
    super.sceneDidDisconnect(scene)
  }

  override func scene(
    _ scene: UIScene,
    openURLContexts URLContexts: Set<UIOpenURLContext>
  ) {
    IncomingUriChannelBridge.shared.handle(urlContexts: URLContexts)
    let remaining = URLContexts.filter {
      !IncomingUriChannelBridge.shared.handles($0.url)
    }
    if !remaining.isEmpty {
      super.scene(scene, openURLContexts: Set(remaining))
    }
  }

  override func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    if IncomingUriChannelBridge.shared.handle(userActivity: userActivity) {
      return
    }
    super.scene(scene, continue: userActivity)
  }
}

/// A native, opaque app-switcher cover. It never changes screenshot exclusion
/// (SecureScreenshotShield owns that policy for sensitive screens only).
/// Kept with SceneDelegate so every Runner build includes the lifecycle owner.
final class AppPrivacyOverlay {
  private let windows: () -> [UIWindow]
  private var covers: [ObjectIdentifier: UIView] = [:]

  init(windows: @escaping () -> [UIWindow]) {
    self.windows = windows
  }

  func show() {
    UIView.performWithoutAnimation {
      for window in windows() {
        let key = ObjectIdentifier(window)
        let cover = covers[key] ?? makeCover()
        cover.frame = window.bounds
        if cover.superview !== window {
          window.addSubview(cover)
        }
        window.bringSubviewToFront(cover)
        cover.layoutIfNeeded()
        covers[key] = cover
      }
    }
  }

  func hide() {
    covers.values.forEach { $0.removeFromSuperview() }
    covers.removeAll()
  }

  private func makeCover() -> UIView {
    let cover = UIView()
    cover.backgroundColor = UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor(red: 20 / 255, green: 24 / 255, blue: 24 / 255, alpha: 1)
        : .white
    }
    cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    cover.isAccessibilityElement = true
    cover.accessibilityLabel = "Sensitive content hidden"
    cover.accessibilityViewIsModal = true
    let lock = UIImageView(image: UIImage(systemName: "lock.fill"))
    lock.tintColor = .label
    lock.contentMode = .scaleAspectFit
    lock.translatesAutoresizingMaskIntoConstraints = false
    cover.addSubview(lock)
    NSLayoutConstraint.activate([
      lock.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
      lock.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
      lock.widthAnchor.constraint(equalToConstant: 50),
      lock.heightAnchor.constraint(equalToConstant: 50),
    ])
    return cover
  }
}
