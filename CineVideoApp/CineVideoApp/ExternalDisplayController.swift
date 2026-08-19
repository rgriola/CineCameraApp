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
/// Driven by the `UIWindowSceneSessionRoleExternalDisplayNonInteractive`
/// scene role (`ExternalDisplaySceneDelegate` in this file's neighbor).
/// Two things were required to get this to actually connect, confirmed via
/// on-device testing:
///
/// 1. A prior attempt to assign the role's delegate class *dynamically*,
///    from `AppDelegate.application(_:configurationForConnecting:options:)`,
///    never resulted in that method even being called for the external
///    role — only ever for the app's own main scene. Declaring the
///    configuration *statically* by name in the scene manifest (see
///    `Info.plist`) is what actually gets `ExternalDisplaySceneDelegate`
///    connected.
/// 2. A classic pre-Scene-API fallback (`UIScreen.didConnectNotification` +
///    a plain `UIWindow` with `window.screen` set directly) was tried and
///    confirmed NOT to work on this iOS version: the window was created
///    successfully and even received camera frames, but the physical HDMI
///    output kept showing the system's own full-device mirror instead —
///    modern UIKit routes presentation through a window's `UIWindowScene`,
///    not the deprecated per-window `.screen` property, so a scene-less
///    window is effectively inert for actual display output.
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

    /// Waits for `CameraManager`'s capture session to finish configuring
    /// (i.e. `videoDevice` becomes non-nil) before creating the HDMI preview
    /// layer at all. Building the layer against a session with no inputs yet
    /// — which can easily happen since the external-display scene can
    /// connect within milliseconds of launch, well before the async
    /// permission cascade finishes configuring the session — previously left
    /// this preview layer (and, in an earlier single-preview-layer design,
    /// even the on-device `CameraPreview`'s own layer) without a working
    /// connection.
    func attachWhenReady(to windowScene: UIWindowScene) {
        guard CameraManager.shared.videoDevice != nil else {
            Logger.externalDisplay.notice("Session not configured yet; deferring HDMI attach.")
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.attachWhenReady(to: windowScene)
            }
            return
        }
        attach(to: windowScene)
    }

    private func attach(to windowScene: UIWindowScene) {
        let window = UIWindow(windowScene: windowScene)
        window.backgroundColor = .black
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

        // TEMPORARY DIAGNOSTIC — remove once confirmed. If the physical HDMI
        // monitor shows this solid magenta card with the label text, this
        // scene-backed UIWindow IS what iOS is actually presenting on that
        // screen. If the monitor instead still shows the full device screen
        // (Dynamic Island, record button, SwiftUI UI) and NOT magenta, the
        // scene still isn't taking over display output.
        if Self.showDiagnosticCard {
            let label = UILabel(frame: window.bounds)
            label.text = "HDMI SCENE WINDOW\n(if you see this, the scene IS live)"
            label.textColor = .white
            label.font = .boldSystemFont(ofSize: 40)
            label.numberOfLines = 0
            label.textAlignment = .center
            let card = UIView(frame: window.bounds)
            card.backgroundColor = .magenta
            card.addSubview(label)
            view.addSubview(card)
        }

        CameraManager.shared.attachSecondaryPreviewLayer(layer) { [weak self] success in
            guard let self, self.previewLayer === layer else { return }
            guard success else {
                Logger.externalDisplay.error("Failed to attach HDMI preview connection.")
                return
            }
            self.attachRotationCoordinator(to: layer)
            Logger.externalDisplay.notice("HDMI mirror window attached to external-display scene.")
        }

        enableAudioMirroring()
    }

    /// Temporary diagnostic switch — see the comment at its one call site in
    /// `attach(to:)`. Set to `false` (or delete this whole block) once we've
    /// confirmed whether the scene-backed `UIWindow` is actually what's being
    /// presented on the physical external display.
    private static let showDiagnosticCard = true

    func teardown() {
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
