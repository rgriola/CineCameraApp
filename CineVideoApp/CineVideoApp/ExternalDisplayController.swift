//
//  ExternalDisplayController.swift
//  CineVideoApp
//
//  Created by rgriola on 8/18/26.
//

import UIKit
@preconcurrency import AVFoundation
import CoreMedia
import OSLog

/// Mirrors the live camera session to an external display connected via a
/// USB‑C/Lightning → HDMI adapter, matching whatever orientation the
/// recording connection is currently using, and freezing in lockstep with it
/// once recording starts — exactly as the original spec's safety net
/// requires.
///
/// Driven by the `UIWindowSceneSessionRoleExternalDisplayNonInteractive`
/// scene role (`ExternalDisplaySceneDelegate` in this file's neighbor), fed
/// by `CameraManager`'s `AVCaptureVideoDataOutput` via
/// `AVSampleBufferDisplayLayer` rather than a second `AVCaptureVideoPreviewLayer`.
/// Three things were required to get a genuinely clean HDMI feed working,
/// each confirmed via on-device testing:
///
/// 1. A prior attempt to assign the external-display scene role's delegate
///    class *dynamically*, from
///    `AppDelegate.application(_:configurationForConnecting:options:)`,
///    never resulted in that method even being called for that role — only
///    ever for the app's own main scene. Declaring the configuration
///    *statically* by name in the scene manifest (see `Info.plist`) is what
///    actually gets `ExternalDisplaySceneDelegate` connected.
/// 2. A classic pre-Scene-API fallback (`UIScreen.didConnectNotification` +
///    a plain `UIWindow` with `window.screen` set directly) was tried and
///    confirmed NOT to work on this iOS version: the window was created
///    successfully and even received camera frames, but the physical HDMI
///    output kept showing the system's own full-device mirror instead —
///    modern UIKit routes presentation through a window's `UIWindowScene`,
///    not the deprecated per-window `.screen` property, so a scene-less
///    window is effectively inert for actual display output.
/// 3. A normal (non-multicam) `AVCaptureSession` does not support a second,
///    independent `AVCaptureVideoPreviewLayer` connection sharing the same
///    video input port `CameraPreview`'s own auto-managed layer already
///    uses — confirmed on-device via `canAddConnection` returning false.
///    `AVCaptureVideoDataOutput` is a distinct output type with its own
///    connection/port, so it coexists cleanly with both the on-device
///    preview and the movie file output; its delivered `CMSampleBuffer`s
///    already carry the same rotation angle applied to the movie output's
///    connection (`CameraManager.setupCaptureRotationCoordinator` drives
///    both), so no separate rotation-coordinator logic is needed here.
@MainActor
final class ExternalDisplayController: NSObject {
    static let shared = ExternalDisplayController()
    private override init() { super.init() }

    private var externalWindow: UIWindow?
    private var displayLayer: AVSampleBufferDisplayLayer?
    private var hostView: MirrorDisplayView?
    private let audioMirror = AudioMirror()

    /// Waits for `CameraManager`'s capture session to finish configuring
    /// (i.e. `videoDevice` becomes non-nil) before creating the HDMI mirror
    /// window at all — the external-display scene can connect within
    /// milliseconds of launch, well before the async permission cascade
    /// finishes configuring the session.
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

        let displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
        // Sample buffers from `AVCaptureVideoDataOutput` carry host-clock
        // presentation timestamps; syncing the display layer's timebase to
        // the host clock (running at real-time rate) is what makes each
        // frame appear as soon as it arrives instead of queuing up against
        // an unrelated default timeline.
        if let timebase = try? CMTimebase(sourceClock: CMClockGetHostTimeClock()) {
            try? timebase.setRate(1.0)
            displayLayer.controlTimebase = timebase
        }

        let view = MirrorDisplayView(displayLayer: displayLayer)
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
        self.displayLayer = displayLayer
        hostView = view

        subscribeToVideoFrames(renderer: displayLayer.sampleBufferRenderer)
        enableAudioMirroring()

        Logger.externalDisplay.notice("HDMI mirror window attached to external-display scene.")
    }

    /// Forwards every frame `CameraManager`'s video data output delivers
    /// straight to the display layer's renderer — called from
    /// `sessionQueue`, never the main actor, matching the pattern Apple's
    /// own sample code uses for real-time `AVSampleBufferDisplayLayer`
    /// passthrough (enqueuing directly from the capture-output delegate
    /// queue, no extra hop needed since the renderer is its own
    /// hardware-clocked queue).
    private func subscribeToVideoFrames(renderer: some AVQueuedSampleBufferRendering) {
        CameraManager.shared.setVideoFrameHandler { sampleBuffer in
            renderer.enqueue(sampleBuffer)
        }
    }

    func teardown() {
        CameraManager.shared.setVideoFrameHandler(nil)
        disableAudioMirroring()
        displayLayer?.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        externalWindow?.isHidden = true
        externalWindow = nil
        displayLayer = nil
        hostView = nil
        Logger.externalDisplay.notice("HDMI mirror window torn down.")
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

/// Keeps the display layer's frame in sync with the actual window bounds,
/// rather than a hardcoded point rect that may not match what the connected
/// display reports — avoids incorrect cropping/letterboxing on some monitors.
private final class MirrorDisplayView: UIView {
    private let displayLayer: AVSampleBufferDisplayLayer

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        layer.addSublayer(displayLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer.frame = bounds
    }
}
