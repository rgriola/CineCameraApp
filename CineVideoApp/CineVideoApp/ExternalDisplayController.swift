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
/// USB‑C/Lightning → HDMI adapter.
///
/// TEMPORARY (branch fix/horizontal-preview): hardcoded to Landscape Right,
/// same as `CameraPreview` and the recording connection — see
/// RotationCorrection.swift for why.
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

        applyHardcodedOrientation(to: layer)
        enableAudioMirroring()
        Logger.externalDisplay.notice("HDMI mirror window attached.")
        return window
    }

    /// Tears down the mirror. Called from `ExternalDisplaySceneDelegate.sceneDidDisconnect(_:)`.
    func teardown() {
        disableAudioMirroring()
        previewLayer = nil
        hostView = nil
        Logger.externalDisplay.notice("HDMI mirror window torn down.")
    }

    /// Edge case: external display connected before the camera session
    /// finished configuring (e.g. permissions still pending). Retry briefly
    /// rather than leaving the mirror at whatever default orientation the
    /// connection happened to start with.
    private func applyHardcodedOrientation(to layer: AVCaptureVideoPreviewLayer) {
        guard let connection = layer.connection else {
            Logger.externalDisplay.notice("No connection yet; will retry orientation setup shortly.")
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.previewLayer === layer else { return }
                self.applyHardcodedOrientation(to: layer)
            }
            return
        }
        connection.applyHardcodedLandscapeRight(source: "HDMI", device: CameraManager.shared.videoDevice)
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
