//
//  AppDelegate.swift
//  CineVideoApp
//
//  Created by rgriola on 8/18/26.
//

import UIKit
import OSLog

/// Phone-only interface lock. The preview supplies its own scene; HDMI must
/// never be used to infer the phone's orientation or inherit its lock.
@MainActor
enum OrientationLock {
    private static weak var lockedScene: UIWindowScene?
    private(set) static var lockedMask: UIInterfaceOrientationMask?
    static var isLocked: Bool { lockedMask != nil }

    enum LockError: LocalizedError {
        case cameraSceneUnavailable
        case unsupportedOrientation
        case alreadyLocked

        var errorDescription: String? {
            switch self {
            case .cameraSceneUnavailable:
                "The camera screen isn't active. Return to the camera and try recording again."
            case .unsupportedOrientation:
                "The camera orientation isn't ready. Hold the phone in portrait or landscape right and try again."
            case .alreadyLocked:
                "A recording is already starting or in progress."
            }
        }
    }

    static func mask(for orientation: UIInterfaceOrientation) throws -> UIInterfaceOrientationMask {
        switch orientation {
        case .portrait: return .portrait
        case .landscapeRight: return .landscapeRight
        default: throw LockError.unsupportedOrientation
        }
    }

    static func supportedMask(
        for role: UISceneSession.Role?,
        phoneLock: UIInterfaceOrientationMask?
    ) -> UIInterfaceOrientationMask {
        if role == .windowExternalDisplayNonInteractive || role == .windowExternalDisplay {
            return .landscapeRight
        }
        return phoneLock ?? [.portrait, .landscapeRight]
    }

    static func lock(in scene: UIWindowScene?) throws {
        guard !isLocked else { throw LockError.alreadyLocked }
        guard let scene, scene.session.role == .windowApplication,
              scene.activationState == .foregroundActive else {
            throw LockError.cameraSceneUnavailable
        }
        let current: UIInterfaceOrientation
        if #available(iOS 26.0, *) {
            current = scene.effectiveGeometry.interfaceOrientation
        } else {
            current = scene.interfaceOrientation
        }
        lockedMask = try mask(for: current)
        lockedScene = scene
        Logger.orientation.notice("Phone orientation locked: scene=\(scene.session.persistentIdentifier, privacy: .public), role=\(scene.session.role.rawValue, privacy: .public), orientation=\(current.rawValue, privacy: .public).")
        requestUpdate(in: scene)
    }

    static func unlock() {
        let scene = lockedScene
        lockedMask = nil
        lockedScene = nil
        Logger.orientation.notice("Phone orientation unlocked.")
        if let scene { requestUpdate(in: scene) }
    }

    static func supportedMask(for window: UIWindow?) -> UIInterfaceOrientationMask {
        let scene = window?.windowScene
        let phoneLock = scene != nil && scene === lockedScene ? lockedMask : nil
        return supportedMask(for: scene?.session.role, phoneLock: phoneLock)
    }

    private static func requestUpdate(in scene: UIWindowScene) {
        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }
}

/// The phone supports Portrait + Landscape Right, narrowed during recording.
/// External-display windows stay landscape independently of that phone lock.
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
        OrientationLock.supportedMask(for: window)
    }
}
