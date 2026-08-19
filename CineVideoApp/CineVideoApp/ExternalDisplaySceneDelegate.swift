//
//  ExternalDisplaySceneDelegate.swift
//  CineVideoApp
//
//  Created by rgriola on 8/18/26.
//

import UIKit
import OSLog

/// Scene delegate for the `UIWindowSceneSessionRoleExternalDisplayNonInteractive`
/// role, statically registered by name in `Info.plist`'s
/// `UIApplicationSceneManifest` → `UISceneConfigurations`. UIKit connects a
/// scene with this role — and instantiates this delegate — whenever an
/// external display (USB‑C/Lightning → HDMI adapter, AirPlay, etc.) becomes
/// available while the app is running.
///
/// All actual window/preview-layer/rotation work lives in
/// `ExternalDisplayController` (a plain, testable, non-UIKit-lifecycle
/// singleton); this delegate is intentionally just the thin UIKit-mandated
/// glue that hands the connecting `UIWindowScene` off to it.
final class ExternalDisplaySceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        Logger.externalDisplay.notice("External-display scene connecting.")
        Task { @MainActor in
            ExternalDisplayController.shared.attachWhenReady(to: windowScene)
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        Logger.externalDisplay.notice("External-display scene disconnected.")
        Task { @MainActor in
            ExternalDisplayController.shared.teardown()
        }
    }
}
