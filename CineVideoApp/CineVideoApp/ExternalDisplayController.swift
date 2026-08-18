//
//  ExternalDisplayController.swift
//  CineVideoApp
//
//  Created by rgriola on 8/18/26.
//

import UIKit
@preconcurrency import AVFoundation
import OSLog

/// Mirrors the live camera session to an external display connected via a
/// USB‑C/Lightning → HDMI adapter, matching whatever orientation the
/// on-device preview and recording are currently using — the same
/// `AVCaptureDevice.RotationCoordinator`-driven approach `CameraPreview` uses,
/// so the HDMI feed always shows exactly "Preview + Recording" as originally
/// specified, and freezes in lockstep with them once recording starts.
///
/// Driven directly by `UIScreen.didConnectNotification`/`didDisconnectNotification`
/// — the classic, pre-Scene-API mechanism (available since iOS 3.2). On-device
/// testing confirmed the modern Scene-based external-display auto-connection
/// (`UISceneSession.Role.windowExternalDisplayNonInteractive`) never actually
/// requests a scene for a plain iPhone + USB‑C/HDMI adapter — that automatic
/// behavior appears to be iPad/Stage-Manager-oriented, not general iPhone
/// hardware. `UIScreen.didConnectNotification`, though deprecated since iOS 16
/// in favor of the Scene mechanism, is still fully functional and was
/// confirmed firing reliably with the correct external `UIScreen` in testing.
///
/// `UIWindow`/`UIScreen` have no SwiftUI equivalent for supplying independent
/// content to a second physical display, so this stays an isolated, minimal
/// UIKit bridge — the same category of interop as `CameraPreview`'s
/// `UIViewRepresentable`.
@MainActor
final class ExternalDisplayController: NSObject {
    static let shared = ExternalDisplayController()
    private override init() { super.init() }

    private var externalWindow: UIWindow?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hostView: MirrorPreviewView?
    private let audioMirror = AudioMirror()

    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private weak var rotationDevice: AVCaptureDevice?
    private var isOrientationLocked = false

    /// Begins observing for external displays. Call once, as early as
    /// possible (from `AppDelegate.application(_:didFinishLaunchingWithOptions:)`),
    /// so a display already connected at launch is picked up immediately, and
    /// any later connect/disconnect is handled for the rest of the app's
    /// lifetime.
    func start() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenDidConnect),
            name: UIScreen.didConnectNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenDidDisconnect),
            name: UIScreen.didDisconnectNotification, object: nil
        )

        // UIScreen.screens[0] is always the built-in display; anything after
        // that is an external screen already connected before this method ran.
        if let externalScreen = UIScreen.screens.dropFirst().first {
            attachWhenReady(to: externalScreen)
        }
    }

    @objc private func screenDidConnect(_ notification: Notification) {
        guard let screen = notification.object as? UIScreen else { return }
        Logger.externalDisplay.notice("External screen connected: \(screen.bounds.width, privacy: .public)x\(screen.bounds.height, privacy: .public).")
        attachWhenReady(to: screen)
    }

    @objc private func screenDidDisconnect(_ notification: Notification) {
        Logger.externalDisplay.notice("External screen disconnected.")
        teardown()
    }

    /// Waits for `CameraManager`'s capture session to finish configuring
    /// (i.e. `videoDevice` becomes non-nil) before creating the HDMI preview
    /// layer at all. Building `AVCaptureVideoPreviewLayer(session:)` before
    /// the session has any inputs — which was happening here, since a
    /// display already connected at launch triggers this within
    /// milliseconds, well before the async permission cascade finishes
    /// configuring the session — left this preview layer without a working
    /// connection, and was empirically found to also disrupt the on-device
    /// `CameraPreview`'s own connection when both raced to attach to the
    /// same not-yet-configured session.
    private func attachWhenReady(to screen: UIScreen) {
        guard CameraManager.shared.videoDevice != nil else {
            Logger.externalDisplay.notice("Session not configured yet; deferring HDMI attach.")
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.attachWhenReady(to: screen)
            }
            return
        }
        attach(to: screen)
    }

    private func attach(to screen: UIScreen) {
        let window = UIWindow(frame: screen.bounds)
        // `UIWindow.screen` is deprecated in favor of the Scene-based
        // `UIWindow(windowScene:)` initializer, but remains the only way to
        // present a window on a screen iOS never assigns a Scene to (see the
        // type-level comment above) — still fully functional as of iOS 26.
        window.screen = screen
        window.backgroundColor = .black
        window.windowLevel = .normal
        window.isHidden = false

        // Deliberately NOT the auto-connecting `AVCaptureVideoPreviewLayer(session:)`
        // initializer `CameraPreview` uses — see
        // `CameraManager.attachSecondaryPreviewLayer`'s doc comment for why
        // a second auto-connected layer isn't safe (it steals the
        // on-device preview's only automatically-managed connection).
        let layer = AVCaptureVideoPreviewLayer()
        layer.videoGravity = .resizeAspect

        let view = MirrorPreviewView(previewLayer: layer)
        view.backgroundColor = .black
        view.frame = window.bounds

        // A plain UIViewController, not hosting any app chrome (no SwiftUI
        // hierarchy, no status bar, no home indicator/Dynamic Island — those
        // only exist on the device's own built-in screen) — this is what
        // keeps the HDMI feed a clean video+audio passthrough.
        let rootViewController = UIViewController()
        rootViewController.view = view
        window.rootViewController = rootViewController
        window.makeKeyAndVisible()

        externalWindow = window
        previewLayer = layer
        hostView = view

        CameraManager.shared.attachSecondaryPreviewLayer(layer) { [weak self] success in
            guard let self, self.previewLayer === layer else { return }
            guard success else {
                Logger.externalDisplay.error("Failed to attach HDMI preview connection.")
                return
            }
            self.attachRotationCoordinator(to: layer)
            Logger.externalDisplay.notice("HDMI mirror window attached to external screen.")
        }

        enableAudioMirroring()
    }

    private func teardown() {
        disableAudioMirroring()
        if let layer = previewLayer {
            CameraManager.shared.detachSecondaryPreviewLayer(layer)
        }
        rotationObservation = nil
        rotationCoordinator = nil
        rotationDevice = nil
        externalWindow?.isHidden = true
        externalWindow = nil
        previewLayer = nil
        hostView = nil
        Logger.externalDisplay.notice("HDMI mirror window torn down.")
    }

    // MARK: - Rotation (mirrors CameraPreview's live device-orientation tracking)

    private func attachRotationCoordinator(to layer: AVCaptureVideoPreviewLayer) {
        guard let device = CameraManager.shared.videoDevice else {
            // Edge case: external display connected before the camera
            // session finished configuring (e.g. permissions still pending).
            // Retry briefly rather than leaving the mirror at a fixed angle.
            Logger.externalDisplay.notice("No video device yet; will retry rotation setup shortly.")
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.previewLayer === layer else { return }
                self.attachRotationCoordinator(to: layer)
            }
            return
        }

        // Freeze/unfreeze in lockstep with the on-device preview and
        // recording, exactly as the original spec's safety net requires.
        CameraManager.shared.onOrientationLockChange = { [weak self] locked in
            self?.updateLockState(isRecording: locked)
        }
        isOrientationLocked = CameraManager.shared.isRecording
        rotationDevice = device

        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        rotationCoordinator = coordinator
        apply(coordinator.videoRotationAngleForHorizonLevelPreview, to: layer)

        rotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview, options: [.new]
        ) { [weak self] _, change in
            guard let newAngle = change.newValue else { return }
            Task { @MainActor [weak self] in
                self?.apply(newAngle)
            }
        }
    }

    private func updateLockState(isRecording: Bool) {
        let wasLocked = isOrientationLocked
        isOrientationLocked = isRecording
        if wasLocked, !isRecording, let coordinator = rotationCoordinator {
            apply(coordinator.videoRotationAngleForHorizonLevelPreview)
        }
    }

    private func apply(_ angle: CGFloat, to layer: AVCaptureVideoPreviewLayer? = nil) {
        guard !isOrientationLocked else {
            Logger.externalDisplay.debug("HDMI apply skipped: orientation locked (recording).")
            return
        }
        guard let layer = layer ?? previewLayer else {
            Logger.externalDisplay.warning("HDMI apply skipped: no preview layer.")
            return
        }
        guard let connection = layer.connection else {
            Logger.externalDisplay.warning("HDMI apply skipped: previewLayer.connection is nil.")
            return
        }
        connection.applyRotationAngle(angle, source: "HDMI", device: rotationDevice)
    }

    // MARK: - Audio follows video

    /// Starts/stops `AudioMirror` playing the session's live audio, so sound
    /// accompanies the picture on the external display. All mutation of the
    /// shared `AVCaptureSession` is funneled through `CameraManager`'s own
    /// serial queue — never touched directly on the main thread — since
    /// `AVCaptureSession` isn't safe for concurrent configuration.
    private func enableAudioMirroring() {
        CameraManager.shared.withSessionQueue { [audioMirror] session in
            audioMirror.start(on: session)
        }
    }

    private func disableAudioMirroring() {
        CameraManager.shared.withSessionQueue { [audioMirror] session in
            audioMirror.stop(on: session)
        }
    }
}

/// Keeps the preview layer's frame in sync with the actual window bounds,
/// rather than a hardcoded point rect that may not match what the connected
/// display reports — avoids incorrect cropping/letterboxing on some monitors.
private final class MirrorPreviewView: UIView {
    private let previewLayer: AVCaptureVideoPreviewLayer

    init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        super.init(frame: .zero)
        layer.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }
}
