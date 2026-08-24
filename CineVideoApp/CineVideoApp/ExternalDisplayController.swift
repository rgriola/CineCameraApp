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
import os

/// Mirrors the live camera session to an external display connected via a
/// USB‑C/Lightning → HDMI adapter. The HDMI feed is always shown horizontal
/// (landscape), regardless of how the device is physically held or rotated —
/// matching how dedicated HDMI-monitoring camera apps (e.g. Blackmagic
/// Camera) behave, since an external monitor is normally mounted/viewed
/// independently of the operator's grip. See
/// `CameraManager.lockHDMIToLandscape`.
///
/// Driven by the `UIWindowSceneSessionRoleExternalDisplayNonInteractive`
/// scene role (`ExternalDisplaySceneDelegate` in this file's neighbor), fed
/// by `CameraManager`'s `AVCaptureVideoDataOutput` via
/// `AVSampleBufferDisplayLayer` rather than a second `AVCaptureVideoPreviewLayer`.
/// Several things were required to get a genuinely clean HDMI feed working,
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
///    preview and the movie file output.
/// 4. Frames were being delivered but dropped almost immediately after the
///    first one or two — traced to `AVSampleBufferDisplayLayer`'s
///    `controlTimebase` starting at time zero rather than synced to the
///    host clock's actual current reading, causing it to think every
///    incoming frame was scheduled far in the future and backing up its
///    internal queue indefinitely (see `attach(to:)`'s timebase setup).
@MainActor
final class ExternalDisplayController: NSObject {
    static let shared = ExternalDisplayController()
    private override init() { super.init() }

    private var externalWindow: UIWindow?
    private var displayLayer: AVSampleBufferDisplayLayer?
    private var hostView: MirrorDisplayView?
    private let audioMirror = AudioMirror()

    /// Presents the HDMI mirror window the instant the external-display scene
    /// connects — unconditionally, and independent of whether the capture
    /// session is ready yet.
    ///
    /// This ordering is load-bearing. iOS keeps showing its default
    /// full-screen DEVICE MIRROR (the entire app UI) on the external display
    /// until an app-owned `UIWindow` is presented on that scene and made key.
    /// The earlier implementation gated window creation behind
    /// `CameraManager.videoDevice != nil`, so any delay — or outright failure —
    /// in the async permission/session-configuration cascade left that
    /// full-UI mirror up: exactly the "HDMI shows the whole app UI" symptom.
    /// The window is now created immediately (black until frames arrive); only
    /// the video-frame + audio wiring waits for the session, in
    /// `wireCaptureWhenReady()`.
    func attach(to windowScene: UIWindowScene) {
        // A scene reconnecting while one is already attached: start clean.
        if externalWindow != nil { teardown() }

        let window = UIWindow(windowScene: windowScene)
        window.backgroundColor = .black
        window.isHidden = false

        let displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
        // Sample buffers from `AVCaptureVideoDataOutput` carry host-clock
        // presentation timestamps reflecting actual device uptime. A fresh
        // `CMTimebase` starts at time ZERO, not synced to its source clock's
        // current reading (confirmed via Apple's docs) — left unset, the
        // display layer would think every incoming frame is scheduled hours
        // in the future relative to its own timeline, backing up its
        // internal queue indefinitely. Explicitly setting the timebase's
        // time to the host clock's current reading is what makes frames
        // display as soon as they arrive instead of queuing forever.
        if let timebase = try? CMTimebase(sourceClock: CMClockGetHostTimeClock()) {
            try? timebase.setTime(CMClockGetTime(CMClockGetHostTimeClock()))
            try? timebase.setRate(1.0)
            displayLayer.controlTimebase = timebase
        }

        let view: MirrorDisplayView = MirrorDisplayView(displayLayer: displayLayer)
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

        Logger.externalDisplay.notice("HDMI mirror window presented; device mirroring stopped.")

        // Window is up and the OS mirror is now replaced; attach the live feed
        // as soon as the capture session has a configured video device.
        wireCaptureWhenReady()
        logStatusShortly(displayLayer: displayLayer)
    }

    /// Subscribes the presented display layer to the camera's video frames and
    /// starts audio mirroring, retrying every 500 ms until `CameraManager`'s
    /// session has finished configuring. Unlike the old approach, this never
    /// blocks the window from appearing — it only fills an already-visible
    /// (black) window with the live feed once it's available. Safe against
    /// teardown: bails out if the window/layer has since been removed.
    private func wireCaptureWhenReady() {
        guard let displayLayer else { return } // torn down before the session was ready
        guard CameraManager.shared.videoDevice != nil else {
            Logger.externalDisplay.notice("HDMI window shown; awaiting capture session before wiring frames.")
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.wireCaptureWhenReady()
            }
            return
        }
        subscribeToVideoFrames(renderer: displayLayer.sampleBufferRenderer)
        enableAudioMirroring()
        Logger.externalDisplay.notice("HDMI live feed wired: video frames + audio mirroring active.")
    }

    /// Forwards every frame `CameraManager`'s video data output delivers
    /// straight to the display layer's renderer — called from
    /// `sessionQueue`, never the main actor, matching the pattern Apple's
    /// own sample code uses for real-time `AVSampleBufferDisplayLayer`
    /// passthrough (enqueuing directly from the capture-output delegate
    /// queue, no extra hop needed since the renderer is its own
    /// hardware-clocked queue).
    private func subscribeToVideoFrames(renderer: some AVQueuedSampleBufferRendering) {
        // `nonisolated(unsafe)` — the renderer is a non-`Sendable` class, but
        // AVFoundation documents `enqueue(_:)` as safe to call from any thread,
        // and this closure only ever runs serially on `CameraManager`'s
        // `videoDataOutputQueue` (the one queue the frame handler runs on), so
        // capturing it into the `@Sendable` closure below is sound. Typed as
        // the concrete existential `any ...` (not the opaque `some`) so no
        // opaque-metatype is captured across the isolation boundary.
        // TODO(Swift 6): remove the unsafe capture if AVFoundation annotates
        // these rendering APIs as `Sendable`.
        nonisolated(unsafe) let renderer: any AVQueuedSampleBufferRendering = renderer
        let counter = OSAllocatedUnfairLock(initialState: 0)
        CameraManager.shared.setVideoFrameHandler { sampleBuffer in
            renderer.enqueue(sampleBuffer)
            let count = counter.withLock { count -> Int in
                count += 1
                return count
            }
            if count == 1 || count % 150 == 0 {
                Logger.externalDisplay.debug("HDMI renderer enqueue #\(count, privacy: .public).")
            }
        }
    }

    /// Temporary diagnostic — checks the display layer's render status a
    /// couple seconds after attach, from the main actor (avoids capturing
    /// the non-`Sendable` `AVSampleBufferDisplayLayer` in the per-frame
    /// `sessionQueue` closure above).
    private func logStatusShortly(displayLayer: AVSampleBufferDisplayLayer) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.displayLayer === displayLayer else { return }
            Logger.externalDisplay.debug("HDMI display layer status=\(String(describing: displayLayer.status), privacy: .public), error=\(String(describing: displayLayer.error), privacy: .public), bounds=\(String(describing: displayLayer.bounds), privacy: .public).")
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
