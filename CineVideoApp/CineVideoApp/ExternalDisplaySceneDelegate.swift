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
            ExternalDisplayController.shared.attach(to: windowScene)
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        Logger.externalDisplay.notice("External-display scene disconnected.")
        Task { @MainActor in
            ExternalDisplayController.shared.teardown()
        }
    }
}

// MARK: - iOS 27+ scene-accessory registration (DORMANT — enable on the iOS 27 SDK)
//
// Beginning in iOS 27, the static `UISceneConfigurations` manifest in
// `Info.plist` NO LONGER auto-connects the external-display scene. The app must
// instead register a "scene accessory" from a live `UIViewController` and keep
// the returned registration object alive for as long as it wants to be able to
// drive the external display. On iOS 26 and earlier the Info.plist manifest
// still auto-connects, so KEEP BOTH — the manifest for iOS ≤ 26, this for ≥ 27.
//
// This block is intentionally disabled with `#if false` because the symbols
// (`registerSceneAccessory`, `UISceneAccessory`, `UISceneConfiguration`'s
// `delegateClass`, `UISceneAccessoryRegistration`) DO NOT EXIST in the iOS 26.5
// SDK this project currently builds against. Referencing them would fail to
// compile even inside an `#available(iOS 27, *)` check, because `#available`
// only guards *runtime* availability, not *SDK* availability.
//
// TO ENABLE, once building against the iOS 27 (or later) SDK:
//   1. Change `#if false` below to `#if true` (or remove the guard entirely).
//   2. Verify the exact API shapes against Apple's current
//      "Presenting content on a connected display" article — the names below
//      reflect the documented iOS 27 API but should be confirmed against the
//      installed SDK headers.
//   3. Surface `ExternalDisplayAccessoryView()` somewhere always-present in the
//      SwiftUI tree so a live view controller performs the registration, e.g.
//      in ContentView's `cameraView`:
//          .background(ExternalDisplayAccessoryView())
#if false
import SwiftUI

/// Hosts a `UIViewController` whose sole job is to register the external-display
/// scene accessory on iOS 27+. Add it to the SwiftUI hierarchy via `.background(...)`.
struct ExternalDisplayAccessoryView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> ExternalDisplayAccessoryController {
        ExternalDisplayAccessoryController()
    }
    func updateUIViewController(_ controller: ExternalDisplayAccessoryController, context: Context) {}
}

final class ExternalDisplayAccessoryController: UIViewController {
    // Must stay alive for the accessory to remain registered.
    private var registration: UISceneAccessoryRegistration?

    override func viewDidLoad() {
        super.viewDidLoad()
        guard #available(iOS 27.0, *), registration == nil else { return }

        let configuration = UISceneConfiguration(
            name: "External Display Configuration",
            sessionRole: .windowExternalDisplayNonInteractive
        )
        configuration.delegateClass = ExternalDisplaySceneDelegate.self

        let accessory = UISceneAccessory.externalNonInteractive(sceneConfiguration: configuration)
        registration = registerSceneAccessory(accessory)
        Logger.externalDisplay.notice("External-display scene accessory registered (iOS 27+ path).")
    }
}
#endif
