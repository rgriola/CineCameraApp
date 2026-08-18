//
//  ExternalDisplaySceneDelegate.swift
//  CineVideoApp
//
//  Created by rgriola on 8/18/26.
//

import UIKit
import OSLog

/// UIKit instantiates this itself for any scene connecting with the
/// `.windowExternalDisplayNonInteractive` role (see
/// `AppDelegate.application(_:configurationForConnecting:options:)`).
///
/// Providing this delegate class is what tells UIKit "this app supplies its
/// own content for the external display" — without it, UIKit still creates
/// the scene but fills it with a default mirror of the main screen, which is
/// what was showing up on the monitor before this fix.
final class ExternalDisplaySceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else {
            Logger.externalDisplay.error("DIAG ExternalDisplaySceneDelegate.scene(_:willConnectTo:) called but scene is not a UIWindowScene.")
            return
        }
        Logger.externalDisplay.error("DIAG ExternalDisplaySceneDelegate.scene(_:willConnectTo:) called — building HDMI window.")
        window = ExternalDisplayController.shared.makeWindow(for: windowScene)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        Logger.externalDisplay.error("DIAG ExternalDisplaySceneDelegate.sceneDidDisconnect called.")
        ExternalDisplayController.shared.teardown()
        window = nil
    }
}
