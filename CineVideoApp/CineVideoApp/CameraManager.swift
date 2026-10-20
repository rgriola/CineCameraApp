//
//  CameraManager.swift
//  CineVideoApp
//
//  Created by rgriola on 8/18/26.
//

@preconcurrency import AVFoundation
import OSLog
import Photos
import SwiftUI
import UIKit

enum RecordingPhase {
    case idle
    case starting
    case recording
    case stopping

    var locksOrientation: Bool { self != .idle }
    var isTransitioning: Bool { self == .starting || self == .stopping }

    mutating func begin() -> Bool {
        guard self == .idle else { return false }
        self = .starting
        return true
    }

    mutating func didStart() -> Bool {
        guard self == .starting else { return false }
        self = .recording
        return true
    }

    mutating func stop() -> Bool {
        guard self == .recording else { return false }
        self = .stopping
        return true
    }

    mutating func finish() { self = .idle }
}

// ---------------------------------------------------------------------------
// CameraSession — plain NSObject that owns all AVFoundation objects.
// No @Observable, no @MainActor isolation. Lives entirely on sessionQueue.
// Conforms to AVCaptureFileOutputRecordingDelegate via nonisolated extension.
// ---------------------------------------------------------------------------

private final class CameraSession: NSObject, @unchecked Sendable {
    // `nonisolated(unsafe)` — these fields are not protected by the compiler;
    // each is instead owned by exactly one serial queue and only ever touched
    // there. Most are owned by `CameraManager.sessionQueue`; the frame-path
    // fields (`onVideoFrame`, `videoFrameLogCount`, `videoFrameDropCount`) are
    // owned by `videoDataOutputQueue` (the sample-buffer delegate's queue); the
    // `onRecordingStateChange` / `onSaveError` hooks are set once before capture
    // begins and only read afterward. Some AVFoundation types also carry
    // version-conditioned MainActor isolation in this SDK; this opts these
    // stored properties out of that entirely, since access is already manually
    // serialized by convention.
    nonisolated(unsafe) let session      = AVCaptureSession()
    nonisolated(unsafe) let movieOutput  = AVCaptureMovieFileOutput()
    // Feeds the HDMI mirror (`ExternalDisplayController`) with raw frames.
    // A normal (non-multicam) `AVCaptureSession` only supports ONE preview-
    // layer connection per input port — confirmed on-device: manually adding
    // a second `AVCaptureConnection(inputPort:videoPreviewLayer:)` for the
    // same port `CameraPreview`'s auto-managed layer already uses failed
    // `canAddConnection`. A video data output is a distinct output type with
    // its own connection/port, so it can coexist with both the preview
    // layer's auto-managed connection and the movie file output.
    nonisolated(unsafe) let videoDataOutput = AVCaptureVideoDataOutput()
    nonisolated(unsafe) var videoInput:  AVCaptureDeviceInput?
    nonisolated(unsafe) var audioInput:  AVCaptureDeviceInput?
    nonisolated(unsafe) var videoDevice: AVCaptureDevice?
    nonisolated(unsafe) var isConfigured = false

    // Drives the movie output connection's rotation angle as the device turns.
    nonisolated(unsafe) var captureRotationCoordinator: AVCaptureDevice.RotationCoordinator?
    nonisolated(unsafe) var captureRotationObservation: NSKeyValueObservation?

    // Tracks the live zoom factor (Phase 3) so the published control
    // snapshot reflects reality during a ramp, a pinch gesture, or any other
    // zoom change not initiated through `CameraManager`'s own methods —
    // `videoZoomFactor` is documented as KVO-observable for exactly this.
    nonisolated(unsafe) var zoomObservation: NSKeyValueObservation?

    // Tracks `focusMode` (Phase 4) so the published snapshot's
    // `isFocusLocked` reflects the automatic `.autoFocus` → `.locked`
    // transition a tap-to-focus settles into on its own, not just changes
    // `CameraManager` makes explicitly — `focusMode` is documented
    // KVO-observable for exactly this.
    nonisolated(unsafe) var focusModeObservation: NSKeyValueObservation?

    // Tracks `exposureMode` (Phase 5) so the published snapshot's
    // `isExposureLocked` reflects the automatic `.autoExpose` → `.locked`
    // transition `exposeAndMeter(at:)` settles into on its own — mirrors
    // `focusModeObservation` exactly; `exposureMode` is documented
    // KVO-observable for the same reason.
    nonisolated(unsafe) var exposureModeObservation: NSKeyValueObservation?

    // Tracks `exposureTargetBias` (Phase 5) so the published snapshot's
    // `exposureBias` reflects the value once `setExposureTargetBias(_:completionHandler:)`
    // actually takes effect, the same way `zoomObservation` tracks a ramp
    // settling rather than publishing an optimistic value up front.
    nonisolated(unsafe) var exposureBiasObservation: NSKeyValueObservation?

    // Set true for the duration of a recording. While locked, live rotation
    // updates are ignored — this is the safety net that freezes camera
    // preview, recording, and HDMI output orientation during capture.
    nonisolated(unsafe) var isOrientationLocked = false

    // Callbacks that push state back to the main actor.
    nonisolated(unsafe) var onRecordingStateChange: (@Sendable (Bool) -> Void)?
    nonisolated(unsafe) var onSaveError: (@Sendable (String) -> Void)?

    // Forwards each frame delivered to `videoDataOutput` — set by
    // `CameraManager.setVideoFrameHandler(_:)`, consumed by
    // `ExternalDisplayController` to feed an `AVSampleBufferDisplayLayer`.
    // Owned by `videoDataOutputQueue`: both the write (`setVideoFrameHandler`)
    // and the read (`captureOutput`) happen on that one queue.
    nonisolated(unsafe) var onVideoFrame: (@Sendable (CMSampleBuffer) -> Void)?

    // Diagnostic only — logs the first frame delivered (and periodically
    // thereafter) so we can tell from Console output whether frames are
    // actually reaching this delegate at all, independent of whatever the
    // HDMI mirror does with them.
    nonisolated(unsafe) var videoFrameLogCount = 0
    nonisolated(unsafe) var videoFrameDropCount = 0

    /// The serial queue that owns the mutable fields above. `CameraManager`
    /// injects its own `sessionQueue` here so delegate callbacks that
    /// AVFoundation invokes on its *own* internal queues (e.g. the movie
    /// recording finish handler) can funnel state mutations back onto the one
    /// queue that owns them, instead of racing it.
    nonisolated let sessionQueue: DispatchQueue

    init(sessionQueue: DispatchQueue) {
        self.sessionQueue = sessionQueue
        super.init()
    }
}

extension CameraSession: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        videoFrameLogCount += 1
        if videoFrameLogCount == 1 || videoFrameLogCount % 150 == 0 {
            let hasHandler = onVideoFrame != nil
            let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            let size = imageBuffer.map { "\(CVPixelBufferGetWidth($0))x\(CVPixelBufferGetHeight($0))" } ?? "no image buffer"
            Logger.externalDisplay.debug("VideoDataOutput frame #\(self.videoFrameLogCount, privacy: .public): \(size, privacy: .public), handlerAttached=\(hasHandler, privacy: .public).")
        }
        onVideoFrame?(sampleBuffer)
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Throttled — logging every single drop was itself slow enough to
        // starve this delegate's queue and cause more drops, a feedback loop
        // discovered on-device before `videoDataOutputQueue` was split out
        // from `sessionQueue`.
        videoFrameDropCount += 1
        if videoFrameDropCount == 1 || videoFrameDropCount % 150 == 0 {
            // The drop REASON is what distinguishes a benign startup/thermal
            // congestion transient from a real bug:
            //   • FrameWasLate   — the delegate queue was still busy when the
            //     next frame arrived; with `alwaysDiscardsLateVideoFrames` this
            //     is the expected way a low-latency monitor sheds load. Heavy
            //     at launch (debugger + live log streaming + session spin-up),
            //     should clear once the system settles.
            //   • OutOfBuffers   — the capture buffer pool is exhausted because
            //     something downstream is RETAINING sample buffers (e.g. the
            //     display layer's renderer backing up, or a leak). This one
            //     points at our code and warrants investigation.
            //   • Discontinuity  — an upstream source hiccup; usually transient.
            let reason = Self.dropReason(for: sampleBuffer)
            Logger.externalDisplay.warning("VideoDataOutput dropped frame #\(self.videoFrameDropCount, privacy: .public), reason=\(reason, privacy: .public).")
        }
    }

    /// Reads the `DroppedFrameReason` attachment AVFoundation stamps on every
    /// dropped sample buffer, mapping it to a short stable string for the log.
    nonisolated private static func dropReason(for sampleBuffer: CMSampleBuffer) -> String {
        guard let reason = CMGetAttachment(
            sampleBuffer,
            key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
            attachmentModeOut: nil
        ) as? String else {
            return "unknown"
        }
        return reason
    }
}

extension CameraSession: AVCaptureFileOutputRecordingDelegate {

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        Logger.recording.notice("Recording started: \(fileURL.lastPathComponent, privacy: .public)")
        onRecordingStateChange?(true)
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        Logger.recording.notice("Recording finished: \(outputFileURL.lastPathComponent, privacy: .public)")

        // Release the orientation lock and catch the movie connection up to the
        // device's current angle — funnelled onto `sessionQueue`, which owns
        // `isOrientationLocked` and serializes capture-connection mutation,
        // because this delegate callback runs on AVFoundation's own internal
        // queue, not `sessionQueue`. The HDMI connection is intentionally left
        // untouched — it's permanently locked to landscape (see
        // `lockHDMIToLandscape`), never tracking device orientation at all.
        sessionQueue.async { [self] in
            isOrientationLocked = false
            if let coordinator = captureRotationCoordinator,
               let connection = movieOutput.connection(with: .video) {
                connection.applyRotationAngle(
                    coordinator.videoRotationAngleForHorizonLevelCapture,
                    source: "Recording",
                    device: videoDevice
                )
            }
        }

        onRecordingStateChange?(false)

        if let error {
            Logger.recording.error("Recording failed: \(error.localizedDescription, privacy: .public)")
            onSaveError?("Recording failed: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: outputFileURL)
            return
        }

        saveToPhotoLibrary(outputFileURL)
    }

    nonisolated private func saveToPhotoLibrary(_ url: URL) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard status == .authorized || status == .limited else {
            Logger.recording.error("Cannot save recording — Photo Library permission not granted.")
            onSaveError?("Photo Library permission is required to save recordings.")
            try? FileManager.default.removeItem(at: url)
            return
        }

        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: url, options: nil)
        } completionHandler: { [weak self] success, error in
            try? FileManager.default.removeItem(at: url)
            if let error {
                Logger.recording.error("Failed to save video: \(error.localizedDescription, privacy: .public)")
                self?.onSaveError?("Failed to save video: \(error.localizedDescription)")
            } else if !success {
                Logger.recording.error("Video save did not complete.")
                self?.onSaveError?("Video save did not complete.")
            } else {
                Logger.recording.notice("Video saved to Photo Library.")
            }
        }
    }
}

// ---------------------------------------------------------------------------
// CameraManager — @Observable so SwiftUI tracks state changes.
// UI-facing properties live on the main actor (mutated only via
// DispatchQueue.main.async hops from sessionQueue callbacks).
// Heavy AVFoundation work is done in `nonisolated` methods that run on
// sessionQueue, so no @Sendable closure ever touches @MainActor properties.
// ---------------------------------------------------------------------------

@Observable
final class CameraManager: NSObject {

    /// Single shared instance — the camera session and its state must be the
    /// same object whether it's driven by the main app UI or by the
    /// external-display scene delegate (which UIKit instantiates itself and
    /// can't be handed a SwiftUI-scoped instance via normal init injection).
    static let shared = CameraManager()

    // MARK: - UI state (main actor)
    var isSessionRunning     = false
    private(set) var recordingPhase: RecordingPhase = .idle
    var isRecording: Bool { recordingPhase == .recording || recordingPhase == .stopping }
    var isOrientationLocked: Bool { recordingPhase.locksOrientation }
    // Resolve the actual hosting scene at record-button time, without retaining
    // the view or relying on connected-scene/key-window ordering (HDMI is key).
    @ObservationIgnored weak var cameraPreviewView: UIView?
    var cameraAuthStatus:       AVAuthorizationStatus = .notDetermined
    var microphoneAuthStatus:   AVAuthorizationStatus = .notDetermined
    var photoLibraryAuthStatus: PHAuthorizationStatus = .notDetermined
    var lastError: String?

    /// The recording format the device actually settled on, or `nil` if it is
    /// running something this app doesn't model (which the capture log flags
    /// as an error). Read back from the hardware rather than assumed, so it
    /// can't claim Cine-HD on a device that failed to apply it.
    private(set) var activeFormat: CineFormat?

    /// Device-derived manual-control state, refreshed from `sessionQueue`
    /// whenever the device or its active format changes. The zoom values are
    /// DISPLAY space (what the user sees, e.g. `1.0` == "1×") — see
    /// `ZoomPolicy` for why that distinction matters.
    private(set) var controls: CameraControlSnapshot = .placeholder

    /// The last-known-good format, loaded at launch and updated whenever a
    /// format change actually succeeds. `@ObservationIgnored` — these are a
    /// persistence detail, not UI state; `activeFormat` above is what SwiftUI
    /// should observe. `CaptureResolution`/`CaptureFrameRate`'s raw types
    /// (`String`/`Int`) are exactly what lets `@AppStorage` bind them
    /// directly, with no JSON encoding.
    @ObservationIgnored
    @AppStorage(CineFormat.StorageKey.resolution) private var persistedResolution: CaptureResolution = .hd1080
    @ObservationIgnored
    @AppStorage(CineFormat.StorageKey.frameRate) private var persistedFrameRate: CaptureFrameRate = .fps30

    var session: AVCaptureSession { cs.session }

    /// Notifies observers when the phone lock engages before recording startup
    /// or releases after completion/rejection. HDMI remains fixed independently.
    /// `@ObservationIgnored` because this is a callback hook, not UI state —
    /// `@Observable`'s macro can't synthesize tracking for a MainActor-typed
    /// closure property.
    @ObservationIgnored
    var onOrientationLockChange: (@MainActor (Bool) -> Void)?

    /// The active video device, exposed so `CameraPreview` can build its own
    /// preview-specific `RotationCoordinator`. A genuine stored, macro-tracked
    /// property (not a computed pass-through into `cs.videoDevice`) — SwiftUI's
    /// Observation system only instruments stored properties the @Observable
    /// macro directly generates; a computed property reading into `cs` (a
    /// plain, non-Observable class) would never notify SwiftUI when its value
    /// changed, so `CameraPreview.updateUIView` would never be re-invoked once
    /// the session finished configuring. This must be assigned explicitly on
    /// the main actor alongside `isSessionRunning` (see `setupSession`).
    private(set) var videoDevice: AVCaptureDevice?

    var isAuthorized: Bool {
        cameraAuthStatus == .authorized &&
        microphoneAuthStatus == .authorized &&
        (photoLibraryAuthStatus == .authorized || photoLibraryAuthStatus == .limited)
    }

    var permissionsDenied: Bool {
        cameraAuthStatus       == .denied || cameraAuthStatus       == .restricted ||
        microphoneAuthStatus   == .denied || microphoneAuthStatus   == .restricted ||
        photoLibraryAuthStatus == .denied || photoLibraryAuthStatus == .restricted
    }

    // MARK: - Private
    private let sessionQueue = DispatchQueue(label: "camera.cinevideoapp.sessionQueue")
    private let cs: CameraSession

    /// Injected permission provider — real (`SystemPermissionsService`) in
    /// production, a scripted stub in tests. See `PermissionsService`.
    private let permissions: any PermissionsService

    // Dedicated queue for the video data output's sample buffer delegate
    // callback, deliberately separate from `sessionQueue`. Apple's own
    // guidance is that this callback must stay lightweight and never
    // contend with other session work — confirmed the hard way on-device:
    // sharing `sessionQueue` between per-frame delivery (~30/sec) and
    // configuration/rotation-update work caused near-continuous frame drops
    // (`AVCaptureVideoDataOutput`'s `alwaysDiscardsLateVideoFrames` drops a
    // frame whenever the delegate queue is still busy when the next one
    // arrives).
    private let videoDataOutputQueue = DispatchQueue(label: "camera.cinevideoapp.videoDataOutputQueue")

    convenience override init() {
        self.init(permissions: SystemPermissionsService())
    }

    /// Designated initializer with an injectable `PermissionsService`. The
    /// no-argument `override init()` (used by `shared`) supplies the real
    /// system-backed service; tests pass a scripted stub.
    init(permissions: any PermissionsService) {
        self.permissions = permissions
        cs = CameraSession(sessionQueue: sessionQueue)
        super.init()

        // Callbacks arrive from sessionQueue; hop to main to mutate @Observable state.
        cs.onRecordingStateChange = { [weak self] recording in
            DispatchQueue.main.async {
                guard let self else { return }
                if recording {
                    if !self.recordingPhase.didStart() {
                        Logger.recording.error("Unexpected recording-start callback.")
                    }
                } else {
                    self.recordingPhase.finish()
                    OrientationLock.unlock()
                    self.onOrientationLockChange?(false)
                }
            }
        }
        cs.onSaveError = { [weak self] message in
            DispatchQueue.main.async { self?.lastError = message }
        }
    }

    // MARK: - Public API (called from main actor / UI)

    /// Kicks off the camera → microphone → photo library permission cascade.
    /// Safe to call repeatedly (e.g. from `onAppear`); each stage no-ops once
    /// granted. Launches the async cascade; UI callers don't await it.
    func checkPermissions() {
        Task { await requestAllPermissions() }
    }

    /// The permission cascade itself, `async` so it can be awaited
    /// deterministically in tests. Resolves camera, then microphone, then photo
    /// library — updating the matching `@Observable` status after each — and
    /// finally starts the capture session if everything ended authorized. Each
    /// stage runs even if an earlier one was denied, so the permission-gate UI
    /// reflects every status (only session start is gated on full authorization).
    func requestAllPermissions() async {
        await resolveCameraPermission()
        await resolveMicrophonePermission()
        await resolvePhotoLibraryPermission()
        startSessionIfAuthorized()
    }

    func toggleRecording() {
        guard !recordingPhase.isTransitioning else {
            Logger.recording.notice("Recording request ignored: start/stop already in progress.")
            return
        }
        let cs = self.cs
        if recordingPhase == .recording {
            guard recordingPhase.stop() else { return }
            sessionQueue.async {
                Logger.recording.notice("Stopping recording; keeping orientation locked until completion.")
                cs.movieOutput.stopRecording()
            }
            return
        }
        guard isSessionRunning else {
            lastError = "The camera isn't ready to record. Please try again."
            Logger.recording.error("Recording rejected: capture session isn't running.")
            return
        }
        do {
            try OrientationLock.lock(in: cameraPreviewView?.window?.windowScene)
        } catch {
            lastError = error.localizedDescription
            Logger.orientation.error("Recording rejected: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard recordingPhase.begin() else {
            OrientationLock.unlock()
            Logger.recording.error("Recording rejected: invalid start transition.")
            lastError = "A recording is already starting or in progress."
            return
        }
        onOrientationLockChange?(true)
        sessionQueue.async { [weak self] in
            self?.performStartRecording(cs: cs)
        }
    }

    /// Requests a new recording format (resolution + frame rate). Hard-blocked
    /// while recording (D6) — format changes must never touch the capture
    /// session mid-take. The UI-facing guard here is cooperative; the
    /// authoritative one is `applyFormat`'s own check on `sessionQueue`.
    func setFormat(_ format: CineFormat) {
        guard !isOrientationLocked else {
            lastError = "Can't change the recording format while recording."
            Logger.controls.notice("Format change rejected on main actor: recording in progress.")
            return
        }
        let cs = self.cs
        sessionQueue.async { [weak self] in
            self?.applyFormat(format, cs: cs)
        }
    }

    /// Sets zoom to an absolute DISPLAY-space value (e.g. a slider drag or a
    /// pinch gesture, sampled continuously). Unlike format changes, zoom
    /// remains available **during recording** (D6) — a cine operator pulls
    /// zoom mid-take. Assigning `videoZoomFactor` directly cancels any
    /// in-flight ramp and snaps to the new value (documented
    /// `AVCaptureDevice` behavior), so no separate cancel call is needed here.
    func setZoom(displayed: CGFloat) {
        let cs = self.cs
        sessionQueue.async { [weak self] in
            guard let self, let device = cs.videoDevice else { return }
            self.applyZoom(to: device, displayed: displayed, context: "manual")
        }
    }

    /// Smoothly ramps zoom to a DISPLAY-space value — intended for discrete
    /// lens-preset taps, where an eased transition reads better than an
    /// instant jump. Continuous slider/pinch drags should call
    /// `setZoom(displayed:)` directly for 1:1 responsiveness. `rate` follows
    /// `AVCaptureDevice`'s doubling-per-second convention (a rate of 1.0
    /// doubles the magnification every second); the default is tuned for a
    /// quick-but-eased preset snap, not a continuous drag.
    func rampZoom(toDisplayed displayed: CGFloat, rate: Float = 4.0) {
        let cs = self.cs
        sessionQueue.async { [weak self] in
            guard let self, let device = cs.videoDevice else { return }
            self.performRampZoom(device: device, toDisplayed: displayed, rate: rate)
        }
    }

    /// Eases out of an in-flight ramp without snapping to a new target — e.g.
    /// if the operator grabs the slider mid-ramp. A direct `setZoom(displayed:)`
    /// call doesn't need this itself; see that method's doc comment.
    func cancelZoomRamp() {
        let cs = self.cs
        sessionQueue.async { [weak self] in
            guard let self, let device = cs.videoDevice else { return }
            self.performCancelZoomRamp(device: device)
        }
    }

    /// Tap-to-focus: focuses once at `devicePoint` — DEVICE space, already
    /// converted from a tap's layer point via
    /// `CameraPreview.PreviewUIView.devicePoint(for:)` (D5). Never pass a
    /// raw/normalized view coordinate here; the letterboxed `.resizeAspect`
    /// preview makes naive `x / width` math focus on the wrong subject.
    /// Sets a one-shot `.autoFocus` — the device itself then settles into
    /// `.locked` on its own (documented `AVCaptureDevice` behavior), which
    /// `observeFocusMode`'s KVO picks up; this method doesn't publish an
    /// optimistic "locked" state itself. Allowed live during recording (D6)
    /// — a cine operator racks focus mid-take.
    func focus(at devicePoint: CGPoint) {
        let cs = self.cs
        sessionQueue.async { [weak self] in
            guard let self, let device = cs.videoDevice else { return }
            self.performFocus(device: device, at: devicePoint)
        }
    }

    /// AF/MF toggle: switches `focusMode` between `.continuousAutoFocus`
    /// (`enabled == true`) and `.locked` (`enabled == false`), freezing focus
    /// wherever the lens currently sits. Unlike `focus(at:)`, this never
    /// moves the point of interest — it's the toggle half of the control,
    /// not the tap-to-refocus half; the two stay independently usable per the
    /// plan (unlike PromptCam, which combines focus and exposure lock into
    /// one control). Allowed live during recording (D6).
    func setAutoFocus(_ enabled: Bool) {
        let cs = self.cs
        sessionQueue.async { [weak self] in
            guard let self, let device = cs.videoDevice else { return }
            self.performSetAutoFocus(enabled, device: device)
        }
    }

    /// Tap-to-expose: meters once at `devicePoint` — DEVICE space, same
    /// conversion as `focus(at:)` (D5). Sets a one-shot `.autoExpose` — the
    /// device itself then settles into `.locked` on its own (documented
    /// `AVCaptureDevice` behavior, symmetric with `.autoFocus`), which
    /// `observeExposureMode`'s KVO picks up; this method doesn't publish an
    /// optimistic "locked" state itself. Allowed live during recording (D6).
    func exposeAndMeter(at devicePoint: CGPoint) {
        let cs = self.cs
        sessionQueue.async { [weak self] in
            guard let self, let device = cs.videoDevice else { return }
            self.performExposeAndMeter(device: device, at: devicePoint)
        }
    }

    /// AE/locked toggle: switches `exposureMode` between
    /// `.continuousAutoExposure` (`enabled == true`) and `.locked`
    /// (`enabled == false`), freezing exposure wherever it currently sits.
    /// Stays independently togglable from focus, per the plan (unlike
    /// PromptCam, which combines focus and exposure lock into one control).
    /// Allowed live during recording (D6).
    func setAutoExposure(_ enabled: Bool) {
        let cs = self.cs
        sessionQueue.async { [weak self] in
            guard let self, let device = cs.videoDevice else { return }
            self.performSetAutoExposure(enabled, device: device)
        }
    }

    /// Sets EV bias to an absolute value — e.g. a slider drag, sampled
    /// continuously. Clamped against the device's reported
    /// `min`/`maxExposureTargetBias` before it ever reaches
    /// `setExposureTargetBias(_:completionHandler:)`. EV bias remains
    /// available during recording (D6), same as zoom and focus.
    func setExposureBias(_ ev: Float) {
        let cs = self.cs
        sessionQueue.async { [weak self] in
            guard let self, let device = cs.videoDevice else { return }
            self.performSetExposureBias(ev, device: device)
        }
    }

    /// Incremental EV bias adjustment (e.g. a +/- stepper). Reads the
    /// device's own current `exposureTargetBias` on `sessionQueue` rather
    /// than trusting a possibly-stale value the caller might be holding, then
    /// applies the same clamped absolute set as `setExposureBias(_:)`.
    func adjustExposureBias(by delta: Float) {
        let cs = self.cs
        sessionQueue.async { [weak self] in
            guard let self, let device = cs.videoDevice else { return }
            self.performSetExposureBias(device.exposureTargetBias + delta, device: device)
        }
    }

    /// Resets EV bias to neutral (0.0) — e.g. the EV panel's Reset button.
    func resetExposureBias() {
        setExposureBias(0)
    }

    /// Escape hatch that lets other components (namely `ExternalDisplayController`,
    /// for adding/removing its audio-mirror output) safely mutate the capture
    /// session on the same serial queue `CameraManager` itself uses — never on
    /// the caller's own thread. `AVCaptureSession` isn't safe for concurrent
    /// configuration from multiple threads, so every mutation must funnel
    /// through this one queue.
    nonisolated func withSessionQueue(_ work: @escaping @Sendable (AVCaptureSession) -> Void) {
        let session = cs.session
        sessionQueue.async { work(session) }
    }

    /// Registers (or clears, with `nil`) the callback that receives every
    /// frame delivered to the session's `videoDataOutput` — this is how
    /// `ExternalDisplayController`'s HDMI mirror gets pixels, since a normal
    /// (non-multicam) `AVCaptureSession` can't give it a second, independent
    /// preview-layer connection (see `videoDataOutput`'s doc comment on
    /// `CameraSession`). Frames already carry the same rotation angle applied
    /// to the movie output's connection (`setupCaptureRotationCoordinator`
    /// drives both), so the HDMI feed always matches Recording's orientation
    /// and freeze/unfreeze behavior with no separate rotation logic needed on
    /// the receiving end. The handler write is serialized on
    /// `videoDataOutputQueue` (the same queue that reads it in `captureOutput`),
    /// never the main actor.
    nonisolated func setVideoFrameHandler(_ handler: (@Sendable (CMSampleBuffer) -> Void)?) {
        let cs = self.cs
        // Serialize the write on `videoDataOutputQueue` — the SAME queue the
        // sample-buffer delegate reads `onVideoFrame` on (see `captureOutput`).
        // Writing it on `sessionQueue` (a different queue) while frames were
        // being delivered ~30/sec raced that read: `onVideoFrame` is a closure
        // (a heap reference with ARC retain/release, not an atomic word), so a
        // read racing the write could over-release or observe a torn pointer —
        // an intermittent crash on HDMI connect/disconnect.
        videoDataOutputQueue.async { cs.onVideoFrame = handler }
    }

    // MARK: - Permission cascade (main actor)

    private func resolveCameraPermission() async {
        let status = permissions.cameraStatus()
        cameraAuthStatus = status
        switch status {
        case .authorized:
            Logger.permissions.info("Camera already authorized.")
        case .notDetermined:
            let granted = await permissions.requestCamera()
            Logger.permissions.notice("Camera permission request result: \(granted, privacy: .public)")
            cameraAuthStatus = granted ? .authorized : .denied
        case .denied, .restricted:
            Logger.permissions.notice("Camera permission denied or restricted.")
        @unknown default:
            cameraAuthStatus = .denied
        }
    }

    private func resolveMicrophonePermission() async {
        let status = permissions.microphoneStatus()
        microphoneAuthStatus = status
        switch status {
        case .authorized:
            Logger.permissions.info("Microphone already authorized.")
        case .notDetermined:
            let granted = await permissions.requestMicrophone()
            Logger.permissions.notice("Microphone permission request result: \(granted, privacy: .public)")
            microphoneAuthStatus = granted ? .authorized : .denied
        case .denied, .restricted:
            Logger.permissions.notice("Microphone permission denied or restricted.")
        @unknown default:
            microphoneAuthStatus = .denied
        }
    }

    private func resolvePhotoLibraryPermission() async {
        let status = permissions.photoLibraryStatus()
        photoLibraryAuthStatus = status
        switch status {
        case .authorized, .limited:
            Logger.permissions.info("Photo Library already authorized (add-only).")
        case .notDetermined:
            let newStatus = await permissions.requestPhotoLibrary()
            Logger.permissions.notice("Photo Library permission request result: \(String(describing: newStatus), privacy: .public)")
            photoLibraryAuthStatus = newStatus
        case .denied, .restricted:
            Logger.permissions.notice("Photo Library permission denied or restricted.")
        @unknown default:
            photoLibraryAuthStatus = .denied
        }
    }

    private func startSessionIfAuthorized() {
        guard isAuthorized else { return }
        let cs = self.cs
        // Read on the main actor — `persistedResolution`/`persistedFrameRate`
        // are main-actor-isolated `@AppStorage` properties and must not be
        // touched from `sessionQueue`.
        let initialFormat = CineFormat(resolution: persistedResolution, frameRate: persistedFrameRate)
        sessionQueue.async { [weak self] in self?.setupSession(cs: cs, initialFormat: initialFormat) }
    }

    // MARK: - nonisolated helpers (run on sessionQueue, never touch @MainActor properties)

    // `nonisolated` — Swift will not enforce @MainActor here, so
    // sessionQueue.async can call this without a Sendable-closure error.
    nonisolated private func setupSession(cs: CameraSession, initialFormat: CineFormat) {
        // Never reconfigure inputs/outputs mid-recording — this is the guard
        // that keeps the microphone source locked while capturing.
        guard !cs.isOrientationLocked, !cs.movieOutput.isRecording else { return }

        guard !cs.isConfigured else {
            if !cs.session.isRunning { cs.session.startRunning() }
            let snapshot = cs.videoDevice.map(Self.makeControlSnapshot(for:))
            let appliedFormat = cs.videoDevice.flatMap(Self.currentCineFormat(of:))
            DispatchQueue.main.async { [weak self] in
                self?.videoDevice = cs.videoDevice
                self?.isSessionRunning = cs.session.isRunning
                if let snapshot { self?.controls = snapshot }
                self?.activeFormat = appliedFormat
            }
            return
        }

        configureAudioSession()

        cs.session.beginConfiguration()

        guard let videoDevice = selectVideoDevice() else {
            Logger.camera.error("Failed to find a video device.")
            cs.session.commitConfiguration()
            return
        }

        guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
            Logger.camera.error("Failed to find an audio device.")
            cs.session.commitConfiguration()
            return
        }

        do {
            let videoInput = try AVCaptureDeviceInput(device: videoDevice)
            let audioInput = try AVCaptureDeviceInput(device: audioDevice)

            guard cs.session.canAddInput(videoInput) else {
                Logger.camera.error("Cannot add video input.")
                cs.session.commitConfiguration(); return
            }
            guard cs.session.canAddInput(audioInput) else {
                Logger.camera.error("Cannot add audio input.")
                cs.session.commitConfiguration(); return
            }
            guard cs.session.canAddOutput(cs.movieOutput) else {
                Logger.camera.error("Cannot add movie output.")
                cs.session.commitConfiguration(); return
            }
            guard cs.session.canAddOutput(cs.videoDataOutput) else {
                Logger.camera.error("Cannot add video data output.")
                cs.session.commitConfiguration(); return
            }

            cs.session.addInput(videoInput)
            cs.session.addInput(audioInput)
            cs.session.addOutput(cs.movieOutput)
            cs.session.addOutput(cs.videoDataOutput)

            // Discard late frames rather than queuing them — the HDMI mirror
            // only ever wants the most current frame; buffering stale ones
            // would just add latency to a "live" feed.
            cs.videoDataOutput.alwaysDiscardsLateVideoFrames = true
            // Dedicated queue, NOT sessionQueue — see videoDataOutputQueue's
            // doc comment.
            cs.videoDataOutput.setSampleBufferDelegate(cs, queue: videoDataOutputQueue)
            // 🔒 Project invariant (D4): the HDMI mirror is always 1080p,
            // independent of the selected recording resolution — see
            // `pinHDMIOutputResolution`'s doc comment.
            pinHDMIOutputResolution(cs: cs)

            cs.videoInput   = videoInput
            cs.audioInput   = audioInput
            cs.videoDevice  = videoDevice
            cs.isConfigured = true

            _ = assignFormat(initialFormat, to: videoDevice)
            applyHEVCCodec(cs: cs)

        } catch {
            Logger.camera.error("Failed to create capture inputs: \(error.localizedDescription, privacy: .public)")
            cs.session.commitConfiguration()
            return
        }

        cs.session.commitConfiguration()

        // MUST come after `commitConfiguration()`, not inside the
        // configuration block. Per AVCaptureDevice.h, "the new format and
        // frame rates are applied together in commitConfiguration" — the
        // `activeFormat` assignment above is deferred until here, and
        // applying it resets `videoZoomFactor` to 1.0 and re-derives
        // `min/maxAvailableVideoZoomFactor`. Anchoring inside the block would
        // therefore be silently undone, leaving a virtual device framed at
        // its ultra-wide 0.5× default. The same applies on the fallback path
        // where no format was assigned at all: the session's preset then
        // configures the input's format itself at commit time.
        applyZoom(to: videoDevice, displayed: 1, context: "initial setup")

        cs.session.startRunning()
        Logger.camera.notice("Capture session configured and started.")

        // Rotation coordination is set up after commitConfiguration so the
        // movie output's connection already exists.
        setupCaptureRotationCoordinator(cs: cs, device: videoDevice)
        lockHDMIToLandscape(cs: cs)
        // Registered after the initial zoom anchor above, so startup doesn't
        // produce a redundant KVO-triggered publish — the explicit publish
        // just below already covers that first value.
        observeZoomFactor(cs: cs, device: videoDevice)
        observeFocusMode(cs: cs, device: videoDevice)
        observeExposureMode(cs: cs, device: videoDevice)
        observeExposureBias(cs: cs, device: videoDevice)

        // Snapshotted here, on sessionQueue, after the format and zoom anchor
        // have settled — the available zoom range is format-dependent.
        let snapshot = Self.makeControlSnapshot(for: videoDevice)
        let appliedFormat = Self.currentCineFormat(of: videoDevice)

        DispatchQueue.main.async { [weak self] in
            self?.videoDevice = cs.videoDevice
            self?.isSessionRunning = cs.session.isRunning
            self?.controls = snapshot
            self?.activeFormat = appliedFormat
            // Persists what actually ran, not what was requested — so a
            // relaunch after a fallback retries the format that worked.
            if let appliedFormat {
                self?.persistedResolution = appliedFormat.resolution
                self?.persistedFrameRate = appliedFormat.frameRate
            }
        }
    }

    /// `sessionQueue` counterpart to `setFormat`. Re-checks the recording
    /// guard authoritatively (the main-actor check in `setFormat` is
    /// cooperative — a recording could start in the gap before this reaches
    /// the queue) before touching anything.
    nonisolated private func applyFormat(_ format: CineFormat, cs: CameraSession) {
        guard !cs.isOrientationLocked, !cs.movieOutput.isRecording else {
            Logger.controls.notice("Format change rejected on sessionQueue: recording started before this reached the queue.")
            DispatchQueue.main.async { [weak self] in
                self?.lastError = "Can't change the recording format while recording."
            }
            return
        }
        guard cs.isConfigured, let device = cs.videoDevice else {
            Logger.controls.error("Format change rejected: capture session not configured yet.")
            return
        }

        // Captured BEFORE touching the format — assigning `activeFormat`
        // resets `videoZoomFactor` to 1.0 (see `applyZoom`), so this is what
        // lets a format change preserve the operator's framing instead of
        // silently snapping back to 1×.
        let desiredZoomDisplayed = ZoomPolicy.displayed(
            fromDeviceFactor: device.videoZoomFactor,
            multiplier: device.displayVideoZoomFactorMultiplier
        )

        cs.session.beginConfiguration()
        let applied = assignFormat(format, to: device)
        cs.session.commitConfiguration()

        guard applied != nil else {
            // `assignFormat` already logged the specific failure; the device
            // format itself never changed, so there's nothing to reapply.
            DispatchQueue.main.async { [weak self] in
                self?.lastError = "That format isn't supported on this device."
            }
            return
        }

        // D9: ordered re-application of everything a format change
        // invalidates. MUST run after `commitConfiguration()` — see
        // `setupSession`'s note on why `activeFormat` is deferred to commit.
        reapplyFormatDependentState(to: device, cs: cs, desiredZoomDisplayed: desiredZoomDisplayed)

        let snapshot = Self.makeControlSnapshot(for: device)
        let appliedFormat = Self.currentCineFormat(of: device)

        DispatchQueue.main.async { [weak self] in
            self?.controls = snapshot
            self?.activeFormat = appliedFormat
            if let appliedFormat {
                self?.persistedResolution = appliedFormat.resolution
                self?.persistedFrameRate = appliedFormat.frameRate
            }
        }
    }

    /// D9 — everything an `activeFormat` change invalidates, reapplied in
    /// order: the zoom the operator had dialed in (format changes reset it
    /// to 1.0), the HDMI 1080p pin (D4), and the movie output's codec
    /// (cheap to re-verify; some resolution/codec combinations are
    /// device-dependent). Must run after `commitConfiguration()`.
    nonisolated private func reapplyFormatDependentState(
        to device: AVCaptureDevice,
        cs: CameraSession,
        desiredZoomDisplayed: CGFloat
    ) {
        applyZoom(to: device, displayed: desiredZoomDisplayed, context: "format change")
        pinHDMIOutputResolution(cs: cs)
        applyHEVCCodec(cs: cs)
    }

    /// Reads back the format the device is genuinely running, mapped onto the
    /// app's modeled formats. `nil` means the hardware is on something this
    /// app doesn't model — which only happens when the requested format
    /// couldn't be applied.
    nonisolated private static func currentCineFormat(of device: AVCaptureDevice) -> CineFormat? {
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let duration = CMTimeGetSeconds(device.activeVideoMinFrameDuration)
        guard duration > 0 else { return nil }
        let matched = CineFormat.matching(
            width: dimensions.width,
            height: dimensions.height,
            frameRate: 1.0 / duration
        )
        if matched == nil {
            Logger.camera.error(
                "Device is running an unmodeled format: \(dimensions.width, privacy: .public)x\(dimensions.height, privacy: .public) @ \(1.0 / duration, privacy: .public)fps."
            )
        }
        return matched
    }

    /// Picks the richest available back camera. A virtual multi-lens device is
    /// what makes zoom across focal lengths possible at all; the single-lens
    /// wide-angle camera remains the universal fallback.
    nonisolated private func selectVideoDevice() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: VideoDeviceSelector.preferredTypes,
            mediaType: .video,
            position: .back
        )
        guard let device = VideoDeviceSelector.select(from: discovery.devices) else { return nil }
        Logger.camera.notice(
            "Selected video device: \(device.localizedName, privacy: .public) [\(device.deviceType.rawValue, privacy: .public)], virtual=\(device.isVirtualDevice, privacy: .public), lenses=\(device.constituentDevices.count, privacy: .public)."
        )
        return device
    }

    /// Sets the device's zoom to a user-facing (DISPLAY space) value, clamped
    /// to whatever the device can currently do. Shared by session setup
    /// (anchoring the starting 1× framing — see the call site's note on why
    /// a virtual device defaults to the ultra-wide 0.5× otherwise) and format
    /// changes (restoring the operator's zoom after `activeFormat` resets it
    /// to 1.0 — see `applyFormat`).
    nonisolated private func applyZoom(to device: AVCaptureDevice, displayed: CGFloat, context: String) {
        let deviceFactor = ZoomPolicy.clamp(
            ZoomPolicy.deviceFactor(fromDisplayed: displayed, multiplier: device.displayVideoZoomFactorMultiplier),
            min: device.minAvailableVideoZoomFactor,
            max: device.maxAvailableVideoZoomFactor
        )
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = deviceFactor
            device.unlockForConfiguration()
            Logger.controls.info(
                "Applied zoom (\(context, privacy: .public)): device factor \(deviceFactor, privacy: .public), displayed \(displayed, privacy: .public)×."
            )
        } catch {
            Logger.controls.error("Failed to lock device to apply zoom (\(context, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Smoothly ramps zoom toward a DISPLAY-space target. `ramp(toVideoZoomFactor:withRate:)`
    /// requires the same exclusive configuration lock as a direct assignment —
    /// confirmed against `AVCaptureDevice.h`, which documents an
    /// `NSGenericException` without it.
    nonisolated private func performRampZoom(device: AVCaptureDevice, toDisplayed displayed: CGFloat, rate: Float) {
        let deviceFactor = ZoomPolicy.clamp(
            ZoomPolicy.deviceFactor(fromDisplayed: displayed, multiplier: device.displayVideoZoomFactorMultiplier),
            min: device.minAvailableVideoZoomFactor,
            max: device.maxAvailableVideoZoomFactor
        )
        do {
            try device.lockForConfiguration()
            device.ramp(toVideoZoomFactor: deviceFactor, withRate: rate)
            device.unlockForConfiguration()
            Logger.controls.info(
                "Ramping zoom to device factor \(deviceFactor, privacy: .public) (displayed \(displayed, privacy: .public)×) at rate \(rate, privacy: .public)."
            )
        } catch {
            Logger.controls.error("Failed to lock device to ramp zoom: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Eases out of an in-flight ramp. Also requires `lockForConfiguration()` —
    /// same documented exception as the ramp call itself.
    nonisolated private func performCancelZoomRamp(device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            device.cancelVideoZoomRamp()
            device.unlockForConfiguration()
            Logger.controls.info("Canceled in-flight zoom ramp.")
        } catch {
            Logger.controls.error("Failed to lock device to cancel zoom ramp: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Key-value observes `videoZoomFactor` so the published control snapshot
    /// tracks the lens continuously — during a ramp, a pinch gesture, or any
    /// change not initiated through `CameraManager`'s own methods. Registered
    /// once per device lifetime; mirrors `setupCaptureRotationCoordinator`'s
    /// observation pattern, including the deliberate hop back onto
    /// `sessionQueue` inside the callback — KVO notifications aren't
    /// guaranteed to arrive on the thread the mutation happened on.
    nonisolated private func observeZoomFactor(cs: CameraSession, device: AVCaptureDevice) {
        cs.zoomObservation = device.observe(\.videoZoomFactor, options: [.new]) { [weak self] device, _ in
            guard let self else { return }
            self.sessionQueue.async {
                self.publishControlSnapshot(for: device)
            }
        }
    }

    /// Tap-to-focus. `focusPointOfInterest` must be set *before* `focusMode`
    /// for the new point to take effect — documented on `AVCaptureDevice`:
    /// setting the point alone doesn't initiate a focus operation.
    nonisolated private func performFocus(device: AVCaptureDevice, at devicePoint: CGPoint) {
        guard device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) else {
            Logger.controls.notice("Tap-to-focus skipped: unsupported on this device.")
            return
        }
        let clamped = FocusPolicy.clampDevicePoint(devicePoint)
        do {
            try device.lockForConfiguration()
            device.focusPointOfInterest = clamped
            device.focusMode = .autoFocus
            device.unlockForConfiguration()
            Logger.controls.info(
                "Tap-to-focus at device point (\(clamped.x, privacy: .public), \(clamped.y, privacy: .public))."
            )
        } catch {
            Logger.controls.error("Failed to lock device for tap-to-focus: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// AF/MF toggle. `enabled` selects `.continuousAutoFocus`; disabling it
    /// selects `.locked`, freezing focus wherever the lens currently sits —
    /// no point-of-interest change, unlike `performFocus`.
    nonisolated private func performSetAutoFocus(_ enabled: Bool, device: AVCaptureDevice) {
        let desired: AVCaptureDevice.FocusMode = enabled ? .continuousAutoFocus : .locked
        guard device.isFocusModeSupported(desired) else {
            Logger.controls.notice("Focus mode \(String(describing: desired), privacy: .public) unsupported on this device.")
            return
        }
        do {
            try device.lockForConfiguration()
            device.focusMode = desired
            device.unlockForConfiguration()
            Logger.controls.info("Set focus mode to \(String(describing: desired), privacy: .public).")
        } catch {
            Logger.controls.error("Failed to lock device to set focus mode: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Key-value observes `focusMode` so the published snapshot's
    /// `isFocusLocked` tracks reality — including the automatic
    /// `.autoFocus` → `.locked` transition a tap-to-focus settles into on its
    /// own, which `performFocus` never sets explicitly itself. Mirrors
    /// `observeZoomFactor`'s pattern, including the deliberate hop back onto
    /// `sessionQueue` inside the callback.
    nonisolated private func observeFocusMode(cs: CameraSession, device: AVCaptureDevice) {
        cs.focusModeObservation = device.observe(\.focusMode, options: [.new]) { [weak self] device, _ in
            guard let self else { return }
            self.sessionQueue.async {
                self.publishControlSnapshot(for: device)
            }
        }
    }

    /// Tap-to-expose. `exposurePointOfInterest` must be set *before*
    /// `exposureMode` for the new point to take effect — documented on
    /// `AVCaptureDevice`, symmetric with `performFocus`'s point-before-mode
    /// requirement.
    nonisolated private func performExposeAndMeter(device: AVCaptureDevice, at devicePoint: CGPoint) {
        guard device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) else {
            Logger.controls.notice("Tap-to-expose skipped: unsupported on this device.")
            return
        }
        let clamped = ExposurePolicy.clampDevicePoint(devicePoint)
        do {
            try device.lockForConfiguration()
            device.exposurePointOfInterest = clamped
            device.exposureMode = .autoExpose
            device.unlockForConfiguration()
            Logger.controls.info(
                "Tap-to-expose at device point (\(clamped.x, privacy: .public), \(clamped.y, privacy: .public))."
            )
        } catch {
            Logger.controls.error("Failed to lock device for tap-to-expose: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// AE/locked toggle. `enabled` selects `.continuousAutoExposure`;
    /// disabling it selects `.locked`, freezing exposure wherever it
    /// currently sits — no point-of-interest change, unlike
    /// `performExposeAndMeter`.
    nonisolated private func performSetAutoExposure(_ enabled: Bool, device: AVCaptureDevice) {
        let desired: AVCaptureDevice.ExposureMode = enabled ? .continuousAutoExposure : .locked
        guard device.isExposureModeSupported(desired) else {
            Logger.controls.notice("Exposure mode \(String(describing: desired), privacy: .public) unsupported on this device.")
            return
        }
        do {
            try device.lockForConfiguration()
            device.exposureMode = desired
            device.unlockForConfiguration()
            Logger.controls.info("Set exposure mode to \(String(describing: desired), privacy: .public).")
        } catch {
            Logger.controls.error("Failed to lock device to set exposure mode: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Sets EV bias to a clamped absolute value. `setExposureTargetBias`
    /// throws `NSRangeException` for an out-of-range value and
    /// `NSGenericException` without a configuration lock — both documented
    /// on `AVCaptureDevice` — so the clamp happens first and the lock
    /// brackets the call. No explicit completion handler: `observeExposureBias`'s
    /// KVO publishes the settled value, mirroring how `applyZoom`/`performRampZoom`
    /// rely on `observeZoomFactor` rather than their own completion.
    nonisolated private func performSetExposureBias(_ ev: Float, device: AVCaptureDevice) {
        let clamped = ExposurePolicy.clampBias(ev, min: device.minExposureTargetBias, max: device.maxExposureTargetBias)
        do {
            try device.lockForConfiguration()
            device.setExposureTargetBias(clamped, completionHandler: nil)
            device.unlockForConfiguration()
            Logger.controls.info("Set exposure bias to \(clamped, privacy: .public) EV.")
        } catch {
            Logger.controls.error("Failed to lock device to set exposure bias: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Key-value observes `exposureMode` so the published snapshot's
    /// `isExposureLocked` tracks reality — including the automatic
    /// `.autoExpose` → `.locked` transition `exposeAndMeter(at:)` settles
    /// into on its own. Mirrors `observeFocusMode`'s pattern exactly,
    /// including the deliberate hop back onto `sessionQueue`.
    nonisolated private func observeExposureMode(cs: CameraSession, device: AVCaptureDevice) {
        cs.exposureModeObservation = device.observe(\.exposureMode, options: [.new]) { [weak self] device, _ in
            guard let self else { return }
            self.sessionQueue.async {
                self.publishControlSnapshot(for: device)
            }
        }
    }

    /// Key-value observes `exposureTargetBias` so the published snapshot's
    /// `exposureBias` reflects the value once `setExposureTargetBias`
    /// actually takes effect (it's an asynchronous hardware operation, same
    /// as a zoom ramp) rather than an optimistic value `performSetExposureBias`
    /// would otherwise have to publish itself.
    nonisolated private func observeExposureBias(cs: CameraSession, device: AVCaptureDevice) {
        cs.exposureBiasObservation = device.observe(\.exposureTargetBias, options: [.new]) { [weak self] device, _ in
            guard let self else { return }
            self.sessionQueue.async {
                self.publishControlSnapshot(for: device)
            }
        }
    }

    /// Builds a fresh control snapshot and publishes it to the main actor.
    /// Shared by the zoom entry points, which don't also need to touch
    /// `activeFormat`/persistence — `setupSession`/`applyFormat` publish
    /// those together and build their own snapshot inline.
    nonisolated private func publishControlSnapshot(for device: AVCaptureDevice) {
        let snapshot = Self.makeControlSnapshot(for: device)
        DispatchQueue.main.async { [weak self] in
            self?.controls = snapshot
        }
    }

    /// Reads the device's current control-related values into a `Sendable`
    /// snapshot. Called on `sessionQueue`, where the device is safe to read.
    nonisolated private static func makeControlSnapshot(for device: AVCaptureDevice) -> CameraControlSnapshot {
        CameraControlSnapshot.make(
            zoomFactor: device.videoZoomFactor,
            minZoomFactor: device.minAvailableVideoZoomFactor,
            maxZoomFactor: device.maxAvailableVideoZoomFactor,
            switchOverFactors: device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) },
            displayMultiplier: device.displayVideoZoomFactorMultiplier,
            exposureBias: device.exposureTargetBias,
            minExposureBias: device.minExposureTargetBias,
            maxExposureBias: device.maxExposureTargetBias,
            isMultiLensDevice: device.isVirtualDevice,
            isFocusLocked: device.focusMode == .locked,
            isFocusSupported: device.isFocusModeSupported(.continuousAutoFocus) && device.isFocusModeSupported(.locked),
            isExposureLocked: device.exposureMode == .locked,
            isExposureSupported: device.isExposureModeSupported(.continuousAutoExposure) && device.isExposureModeSupported(.locked)
        )
    }

    /// Maps a device's real `AVCaptureDevice.Format` list into the pure value
    /// descriptors `CaptureFormatSelector`/`FormatResolutionPolicy` operate on.
    nonisolated private static func captureFormatDescriptors(for device: AVCaptureDevice) -> [CaptureFormatDescriptor] {
        device.formats.map { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let ranges = format.videoSupportedFrameRateRanges.map { $0.minFrameRate...$0.maxFrameRate }
            return CaptureFormatDescriptor(width: dimensions.width, height: dimensions.height, frameRateRanges: ranges)
        }
    }

    /// Resolves `requested` against the device's real formats and assigns the
    /// result. Must run inside the caller's `beginConfiguration`/
    /// `commitConfiguration` bracket (this method itself does not call
    /// either) — matches how `AVCaptureDevice.activeFormat` is documented to
    /// be set. Returns the format actually applied (which may differ from
    /// `requested` — see `FormatResolutionPolicy`), or `nil` if nothing on
    /// the device matches HD or 4K at all, in which case the device's
    /// current format is left untouched.
    nonisolated private func assignFormat(_ requested: CineFormat, to device: AVCaptureDevice) -> CineFormat? {
        let descriptors = Self.captureFormatDescriptors(for: device)
        guard let resolved = FormatResolutionPolicy.resolve(in: descriptors, requested: requested) else {
            // Escalated from a warning: since the capture device became a
            // virtual multi-lens device, landing here means the app may be
            // recording at something other than what was requested. The
            // actual dimensions are logged so the regression is diagnosable
            // from Console rather than only visible in the footage.
            let actual = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            Logger.camera.error(
                "No usable \(requested.resolution.rawValue, privacy: .public)/\(requested.frameRate.rawValue, privacy: .public)p format on \(device.localizedName, privacy: .public); leaving device format at \(actual.width, privacy: .public)x\(actual.height, privacy: .public)."
            )
            return nil
        }

        let format = device.formats[resolved.index]
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let duration = CMTime(value: 1, timescale: CMTimeScale(resolved.applied.frameRate.rawValue))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
            Logger.camera.info(
                "Applied format: \(resolved.applied.resolution.dimensionLabel, privacy: .public) @ \(resolved.applied.frameRate.displayLabel, privacy: .public)."
            )
            return resolved.applied
        } catch {
            Logger.camera.error("Failed to lock device for format change: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 🔒 Project invariant (D4): pins the HDMI mirror's video data output to
    /// 1080p, deliberately independent of the selected recording resolution —
    /// see `README.md`'s "HDMI output is always 1080p" note. Protects a
    /// frame-delivery path that already shows drop pressure at 1080p from
    /// ever being asked to carry raw 4K buffers, and keeps the external
    /// monitor a stable signal the same way Blackmagic Camera's HDMI output
    /// behaves. Idempotent and safe to call at any time — unlike
    /// `activeFormat`, `videoSettings` isn't deferred to `commitConfiguration()`.
    nonisolated private func pinHDMIOutputResolution(cs: CameraSession) {
        cs.videoDataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 1920,
            kCVPixelBufferHeightKey as String: 1080,
        ]
    }

    /// Forces H.265/HEVC on the movie output's video connection, falling back
    /// to H.264 only if the device genuinely can't encode HEVC.
    nonisolated private func applyHEVCCodec(cs: CameraSession) {
        guard let connection = cs.movieOutput.connection(with: .video) else { return }
        let codec = CodecSelector.select(from: cs.movieOutput.availableVideoCodecTypes)
        cs.movieOutput.setOutputSettings([AVVideoCodecKey: codec], for: connection)
        Logger.camera.info("Movie output codec set to \(codec.rawValue, privacy: .public).")
    }

    /// Explicitly configures the app's shared `AVAudioSession` for simultaneous
    /// microphone capture and live playback (used by `AudioMirror` to send
    /// audio out an HDMI/USB adapter). Without this, the session's category is
    /// left to whatever AVCaptureSession implicitly picks for recording alone,
    /// which isn't guaranteed to also permit playback once a new audio route
    /// (like HDMI) becomes active.
    nonisolated private func configureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .videoRecording,
                options: [.allowBluetoothA2DP, .defaultToSpeaker]
            )
            try audioSession.setActive(true)
            Logger.camera.info("AVAudioSession configured for playAndRecord.")
        } catch {
            Logger.camera.error("Failed to configure AVAudioSession: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Wires an `AVCaptureDevice.RotationCoordinator` to the movie output's
    /// connection so recorded video always matches how the device is held —
    /// and freezes — unless `cs.isOrientationLocked` is set (during an
    /// active recording). The video data output's connection (feeding the
    /// HDMI mirror) is deliberately NOT driven by this live coordinator —
    /// see `lockHDMIToLandscape`.
    nonisolated private func setupCaptureRotationCoordinator(cs: CameraSession, device: AVCaptureDevice) {
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        cs.captureRotationCoordinator = coordinator

        applyRotationAngle(coordinator.videoRotationAngleForHorizonLevelCapture, cs: cs)

        cs.captureRotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture, options: [.new]
        ) { [weak self] _, change in
            guard let self, let newAngle = change.newValue else { return }
            self.sessionQueue.async {
                self.applyRotationAngle(newAngle, cs: cs)
            }
        }
    }

    nonisolated private func applyRotationAngle(_ angle: CGFloat, cs: CameraSession) {
        guard !cs.isOrientationLocked, let connection = cs.movieOutput.connection(with: .video) else { return }
        connection.applyRotationAngle(angle, source: "Recording", device: cs.videoDevice)
    }

    /// Locks the HDMI mirror's connection to a fixed landscape angle, once,
    /// at setup — it never changes again regardless of how the device is
    /// held or rotated, matching how dedicated HDMI-monitoring camera apps
    /// (e.g. Blackmagic Camera) behave: the external monitor always shows a
    /// horizontal frame, since it's normally mounted/viewed independently of
    /// however the operator is holding the phone. `0°` is this camera's
    /// confirmed Landscape Right angle (see `RotationCorrection.swift`).
    nonisolated private func lockHDMIToLandscape(cs: CameraSession) {
        guard let connection = cs.videoDataOutput.connection(with: .video) else { return }
        connection.applyRotationAngle(0, source: "HDMI", device: cs.videoDevice)
    }

    nonisolated private func performStartRecording(cs: CameraSession) {
        guard cs.isConfigured, cs.session.isRunning,
              !cs.movieOutput.isRecording, !cs.isOrientationLocked else {
            Logger.recording.error("Recording rejected: session unavailable or already recording.")
            cs.onSaveError?("The camera couldn't start recording. Please try again.")
            cs.onRecordingStateChange?(false)
            return
        }

        Logger.recording.notice("Starting recording; locking orientation.")
        // Freeze the movie connection before starting. The phone interface
        // and preview are already locked; HDMI stays fixed independently.
        cs.isOrientationLocked = true

        let outputURL = RecordingURL.makeTemporaryMovieURL()

        cs.movieOutput.startRecording(to: outputURL, recordingDelegate: cs)
    }
}
