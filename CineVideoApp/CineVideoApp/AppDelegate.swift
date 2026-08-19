//
//  AppDelegate.swift
//  CineVideoApp
//
//  Created by rgriola on 8/18/26.
//

import UIKit
import OSLog

/// Shared flag consulted by `AppDelegate` to restrict interface rotation while
/// recording is active. UIKit on iOS 18 calls delegate rotation queries on the
/// main actor, so this is safe to read/write without extra synchronization.
@MainActor
enum OrientationLock {
    private(set) static var isLocked = false
    private(set) static var lockedMask: UIInterfaceOrientationMask = .portrait

    /// Freezes the app to whichever orientation (portrait or landscape right)
    /// the device currently reports. Called when recording starts.
    static func lock() {
        let scene = UIApplication.shared
            .connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let current = scene.map(currentInterfaceOrientation) ?? .portrait

        lockedMask = current.isLandscape ? .landscapeRight : .portrait
        isLocked = true
        Logger.orientation.notice("Orientation locked to \(String(describing: lockedMask), privacy: .public).")
        requestUpdate()
    }

    /// `UIWindowScene.interfaceOrientation` was deprecated in iOS 26 in favor
    /// of `effectiveGeometry.interfaceOrientation`, which isn't available at
    /// this app's iOS 18 deployment target. Isolated here (itself marked
    /// deprecated) so the warning doesn't leak out to `lock()`'s call site.
    @available(iOS, deprecated: 26.0, message: "No iOS 18-compatible replacement yet; intentional.")
    private static func currentInterfaceOrientation(for scene: UIWindowScene) -> UIInterfaceOrientation {
        scene.interfaceOrientation
    }

    /// Releases the lock, allowing the device to rotate freely again between
    /// Portrait and Landscape Right. Called when recording stops.
    static func unlock() {
        isLocked = false
        Logger.orientation.notice("Orientation unlocked.")
        requestUpdate()
    }

    private static func requestUpdate() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
    }
}

/// Minimal delegate whose sole job is to enforce the app-wide orientation
/// restriction: Portrait + Landscape Right only, further narrowed to whichever
/// single orientation is locked while recording.
///
/// The HDMI/external-display mirror no longer needs anything from this
/// delegate — `ExternalDisplaySceneDelegate` (registered statically in
/// `Info.plist`'s scene manifest) is what UIKit connects directly whenever an
/// external display becomes available.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationLock.isLocked ? OrientationLock.lockedMask : [.portrait, .landscapeRight]
    }
}
