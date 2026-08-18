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
/// single orientation is locked while recording. It also hands UIKit a
/// dedicated scene configuration for connected external displays, so a
/// plugged-in monitor gets our own HDMI mirror content (via
/// `ExternalDisplaySceneDelegate`) instead of the OS's default screen mirror.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // TEMPORARY DIAGNOSTIC: UIScreen.didConnectNotification predates the
        // Scene API entirely (iOS 3.2+) and fires whenever iOS recognizes any
        // additional physical/virtual screen, regardless of whether our
        // scene-based mechanism below is working. If this fires but
        // configurationForConnecting never sees a second scene, that proves
        // iOS sees the HDMI display but isn't requesting a distinct scene for
        // it — a different problem than our role-check logic being wrong.
        NotificationCenter.default.addObserver(
            forName: UIScreen.didConnectNotification, object: nil, queue: .main
        ) { notification in
            let screen = notification.object as? UIScreen
            Logger.externalDisplay.error("DIAG UIScreen.didConnectNotification fired. screen=\(String(describing: screen), privacy: .public) totalScreens=\(UIScreen.screens.count, privacy: .public)")
        }
        NotificationCenter.default.addObserver(
            forName: UIScreen.didDisconnectNotification, object: nil, queue: .main
        ) { _ in
            Logger.externalDisplay.error("DIAG UIScreen.didDisconnectNotification fired. totalScreens=\(UIScreen.screens.count, privacy: .public)")
        }
        return true
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationLock.isLocked ? OrientationLock.lockedMask : [.portrait, .landscapeRight]
    }

    /// Without this, UIKit still creates a scene for a connected external
    /// display, but fills it with a default mirror of the app's main screen
    /// rather than invoking any of our own code — that default mirror is
    /// exactly what was showing up on the monitor (including the record
    /// button) instead of the intended HDMI camera preview.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        // TEMPORARY DIAGNOSTIC: .error level, unconditional — confirms this
        // delegate method is even being invoked at all when the external
        // display connects, and what role/name UIKit is actually offering
        // for that connecting session (role is the deciding factor for
        // whether our custom delegate gets attached below).
        Logger.externalDisplay.error("DIAG configurationForConnecting called. role=\(connectingSceneSession.role.rawValue, privacy: .public) name=\(connectingSceneSession.configuration.name ?? "nil", privacy: .public)")

        let configuration = UISceneConfiguration(
            name: connectingSceneSession.configuration.name,
            sessionRole: connectingSceneSession.role
        )

        if connectingSceneSession.role == .windowExternalDisplayNonInteractive {
            Logger.externalDisplay.error("DIAG Role matched windowExternalDisplayNonInteractive — assigning ExternalDisplaySceneDelegate.")
            configuration.delegateClass = ExternalDisplaySceneDelegate.self
        } else {
            Logger.externalDisplay.error("DIAG Role did NOT match windowExternalDisplayNonInteractive — using default configuration.")
        }

        return configuration
    }
}
