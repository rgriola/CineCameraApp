//
//  ExternalDisplayController.swift
//  CineVideoApp
//
//  Created by rgriola on 8/18/26.
//

import UIKit
@preconcurrency import AVFoundation

/// Mirrors the live camera session to an external display connected via a
/// USB‑C/Lightning → HDMI adapter, at a fixed 1920x1080 landscape framing that
/// never changes with device rotation — the HDMI feed is meant for a
/// stationary TV/monitor, not a second handheld screen.
///
/// `UIWindow`/`UIScreen`/`UIScene` have no SwiftUI equivalent for rendering to
/// a second physical display, so this stays an isolated, minimal UIKit bridge
/// — the same category of interop as `CameraPreview`'s `UIViewRepresentable`.
@MainActor
final class ExternalDisplayController: NSObject {
    private let cameraManager: CameraManager
    private var externalWindow: UIWindow?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let audioMirror = AudioMirror()

    init(cameraManager: CameraManager) {
        self.cameraManager = cameraManager
        super.init()

        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneWillConnect),
            name: UIScene.willConnectNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneDidDisconnect),
            name: UIScene.didDisconnectNotification, object: nil
        )

        // Handle a display that was already connected before this controller existed.
        if let existingScene = UIApplication.shared.connectedScenes.first(where: {
            $0.session.role == .windowExternalDisplayNonInteractive
        }) as? UIWindowScene {
            attach(to: existingScene)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func sceneWillConnect(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene,
              scene.session.role == .windowExternalDisplayNonInteractive
        else { return }
        attach(to: scene)
    }

    @objc private func sceneDidDisconnect(_ notification: Notification) {
        guard let scene = notification.object as? UIScene,
              scene.session.role == .windowExternalDisplayNonInteractive
        else { return }
        detach()
    }

    private func attach(to scene: UIWindowScene) {
        let window = UIWindow(windowScene: scene)
        window.backgroundColor = .black

        let layer = AVCaptureVideoPreviewLayer(session: cameraManager.session)
        layer.videoGravity = .resizeAspect
        layer.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        // Fixed landscape framing, set once and never revisited — the TV/
        // monitor image stays stable regardless of device rotation or the
        // recording orientation lock.
        if let connection = layer.connection, connection.isVideoRotationAngleSupported(0) {
            connection.videoRotationAngle = 0
        }

        let hostView = UIView(frame: layer.frame)
        hostView.backgroundColor = .black
        hostView.layer.addSublayer(layer)

        let rootViewController = UIViewController()
        rootViewController.view = hostView
        window.rootViewController = rootViewController
        window.isHidden = false

        externalWindow = window
        previewLayer = layer

        enableAudioMirroring()
    }

    private func detach() {
        disableAudioMirroring()
        externalWindow?.isHidden = true
        externalWindow = nil
        previewLayer = nil
    }

    // MARK: - Audio follows video

    /// Starts `AudioMirror` playing the session's live audio, so sound
    /// accompanies the picture on the external display. Once a connected
    /// HDMI/USB adapter becomes the system's active audio output route, live
    /// playback automatically goes out through it — see `AudioMirror`.
    private func enableAudioMirroring() {
        audioMirror.start(on: cameraManager.session)
    }

    private func disableAudioMirroring() {
        audioMirror.stop(on: cameraManager.session)
    }
}
