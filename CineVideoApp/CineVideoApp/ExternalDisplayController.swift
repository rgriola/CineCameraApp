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
/// Driven entirely by `ExternalDisplaySceneDelegate`'s UIKit-invoked lifecycle
/// callbacks. UIKit instantiates that delegate itself (per the scene
/// configuration returned from `AppDelegate`), so this stays a singleton
/// reachable from it, rather than something owned by SwiftUI view state.
///
/// `UIWindow`/`UIWindowSceneDelegate` have no SwiftUI equivalent for
/// supplying independent content to a second physical display, so this stays
/// an isolated, minimal UIKit bridge — the same category of interop as
/// `CameraPreview`'s `UIViewRepresentable`.
@MainActor
final class ExternalDisplayController {
    static let shared = ExternalDisplayController()
    private init() {}

    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hostView: MirrorPreviewView?
    private let audioMirror = AudioMirror()

    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var isOrientationLocked = false

    /// Builds the window UIKit should use for the external display's scene.
    /// Called from `ExternalDisplaySceneDelegate.scene(_:willConnectTo:options:)`
    /// — this is what supplies our own HDMI mirror instead of the OS's
    /// default screen-mirroring behavior.
    func makeWindow(for windowScene: UIWindowScene) -> UIWindow {
        let window = UIWindow(windowScene: windowScene)
        window.backgroundColor = .black

        let layer = AVCaptureVideoPreviewLayer(session: CameraManager.shared.session)
        layer.videoGravity = .resizeAspect

        let view = MirrorPreviewView(previewLayer: layer)
        view.backgroundColor = .black

        let rootViewController = UIViewController()
        rootViewController.view = view
        window.rootViewController = rootViewController
        window.makeKeyAndVisible()

        previewLayer = layer
        hostView = view

        attachRotationCoordinator(to: layer)
        enableAudioMirroring()
        Logger.externalDisplay.notice("HDMI mirror window attached.")
        return window
    }

    /// Tears down the mirror. Called from `ExternalDisplaySceneDelegate.sceneDidDisconnect(_:)`.
    func teardown() {
        disableAudioMirroring()
        rotationObservation = nil
        rotationCoordinator = nil
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
        guard !isOrientationLocked,
              let layer = layer ?? previewLayer,
              let connection = layer.connection,
              connection.isVideoRotationAngleSupported(angle)
        else { return }
        connection.videoRotationAngle = angle
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
