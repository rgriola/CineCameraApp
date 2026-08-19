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

// ---------------------------------------------------------------------------
// CameraSession — plain NSObject that owns all AVFoundation objects.
// No @Observable, no @MainActor isolation. Lives entirely on sessionQueue.
// Conforms to AVCaptureFileOutputRecordingDelegate via nonisolated extension.
// ---------------------------------------------------------------------------

private final class CameraSession: NSObject, @unchecked Sendable {
    // `nonisolated(unsafe)` — these are only ever touched from sessionQueue
    // (or from delegate callbacks, themselves invoked off-main by AVFoundation).
    // Some AVFoundation types carry version-conditioned MainActor isolation in
    // this SDK; this opts these stored properties out of that entirely, since
    // access is already manually serialized by convention.
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
    nonisolated(unsafe) var onVideoFrame: (@Sendable (CMSampleBuffer) -> Void)?

    // Diagnostic only — logs the first frame delivered (and periodically
    // thereafter) so we can tell from Console output whether frames are
    // actually reaching this delegate at all, independent of whatever the
    // HDMI mirror does with them.
    nonisolated(unsafe) var videoFrameLogCount = 0
    nonisolated(unsafe) var videoFrameDropCount = 0
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
            Logger.externalDisplay.warning("VideoDataOutput dropped frame #\(self.videoFrameDropCount, privacy: .public).")
        }
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

        // Recording has ended — release the orientation lock and immediately
        // catch the movie connection up to wherever the device is currently
        // held. The HDMI connection is intentionally left untouched — it's
        // permanently locked to landscape (see `lockHDMIToLandscape`), never
        // tracking device orientation at all.
        isOrientationLocked = false
        if let coordinator = captureRotationCoordinator,
           let connection = movieOutput.connection(with: .video) {
            connection.applyRotationAngle(
                coordinator.videoRotationAngleForHorizonLevelCapture,
                source: "Recording",
                device: videoDevice
            )
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
    var isRecording          = false
    var cameraAuthStatus:       AVAuthorizationStatus = .notDetermined
    var microphoneAuthStatus:   AVAuthorizationStatus = .notDetermined
    var photoLibraryAuthStatus: PHAuthorizationStatus = .notDetermined
    var lastError: String?

    var session: AVCaptureSession { cs.session }

    /// Notifies observers whenever the orientation lock engages/releases
    /// (i.e., recording starts/stops), so other consumers of the live camera
    /// feed — like `ExternalDisplayController`'s HDMI mirror — can freeze and
    /// unfreeze their own rotation in lockstep with the on-device preview.
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
    private let cs           = CameraSession()
    private let sessionQueue = DispatchQueue(label: "camera.cinevideoapp.sessionQueue")

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

    override init() {
        super.init()

        // Callbacks arrive from sessionQueue; hop to main to mutate @Observable state.
        cs.onRecordingStateChange = { [weak self] recording in
            DispatchQueue.main.async {
                self?.isRecording = recording
                // Lock/unlock the app's UIKit-level interface-orientation mask
                // alongside the AVFoundation-level rotation lock in CameraSession.
                if recording {
                    OrientationLock.lock()
                } else {
                    OrientationLock.unlock()
                }
                self?.onOrientationLockChange?(recording)
            }
        }
        cs.onSaveError = { [weak self] message in
            DispatchQueue.main.async { self?.lastError = message }
        }
    }

    // MARK: - Public API (called from main actor / UI)

    /// Kicks off the camera → microphone → photo library permission cascade.
    /// Safe to call repeatedly (e.g. from `onAppear`); each stage no-ops once granted.
    func checkPermissions() {
        cameraAuthStatus = AVCaptureDevice.authorizationStatus(for: .video)

        switch cameraAuthStatus {
        case .authorized:
            Logger.permissions.info("Camera already authorized.")
            checkMicrophonePermission()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    Logger.permissions.notice("Camera permission request result: \(granted, privacy: .public)")
                    self?.cameraAuthStatus = granted ? .authorized : .denied
                    self?.checkMicrophonePermission()
                }
            }
        case .denied, .restricted:
            Logger.permissions.notice("Camera permission denied or restricted.")
            checkMicrophonePermission() // refresh remaining statuses for the gate UI
        @unknown default:
            cameraAuthStatus = .denied
        }
    }

    func toggleRecording() {
        // Capture cs before leaving the main actor — see setupSession() for explanation.
        let cs = self.cs
        sessionQueue.async { [weak self] in
            self?.performToggleRecording(cs: cs)
        }
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
    /// the receiving end. Invoked on `sessionQueue`, never the main actor —
    /// callers must hop to main themselves before touching UI state.
    nonisolated func setVideoFrameHandler(_ handler: (@Sendable (CMSampleBuffer) -> Void)?) {
        let cs = self.cs
        sessionQueue.async { cs.onVideoFrame = handler }
    }

    // MARK: - Permission cascade (main actor)

    private func checkMicrophonePermission() {
        microphoneAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        switch microphoneAuthStatus {
        case .authorized:
            Logger.permissions.info("Microphone already authorized.")
            checkPhotoLibraryPermission()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    Logger.permissions.notice("Microphone permission request result: \(granted, privacy: .public)")
                    self?.microphoneAuthStatus = granted ? .authorized : .denied
                    self?.checkPhotoLibraryPermission()
                }
            }
        case .denied, .restricted:
            Logger.permissions.notice("Microphone permission denied or restricted.")
            checkPhotoLibraryPermission()
        @unknown default:
            microphoneAuthStatus = .denied
        }
    }

    private func checkPhotoLibraryPermission() {
        photoLibraryAuthStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)

        switch photoLibraryAuthStatus {
        case .authorized, .limited:
            Logger.permissions.info("Photo Library already authorized (add-only).")
            startSessionIfAuthorized()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
                DispatchQueue.main.async {
                    Logger.permissions.notice("Photo Library permission request result: \(String(describing: status), privacy: .public)")
                    self?.photoLibraryAuthStatus = status
                    self?.startSessionIfAuthorized()
                }
            }
        case .denied, .restricted:
            Logger.permissions.notice("Photo Library permission denied or restricted.")
        @unknown default:
            photoLibraryAuthStatus = .denied
        }
    }

    private func startSessionIfAuthorized() {
        guard isAuthorized else { return }
        let cs = self.cs
        sessionQueue.async { [weak self] in self?.setupSession(cs: cs) }
    }

    // MARK: - nonisolated helpers (run on sessionQueue, never touch @MainActor properties)

    // `nonisolated` — Swift will not enforce @MainActor here, so
    // sessionQueue.async can call this without a Sendable-closure error.
    nonisolated private func setupSession(cs: CameraSession) {
        // Never reconfigure inputs/outputs mid-recording — this is the guard
        // that keeps the microphone source locked while capturing.
        guard !cs.movieOutput.isRecording else { return }

        guard !cs.isConfigured else {
            if !cs.session.isRunning { cs.session.startRunning() }
            DispatchQueue.main.async { [weak self] in
                self?.videoDevice = cs.videoDevice
                self?.isSessionRunning = cs.session.isRunning
            }
            return
        }

        configureAudioSession()

        cs.session.beginConfiguration()

        guard let videoDevice = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .back)
        else {
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

            cs.videoInput   = videoInput
            cs.audioInput   = audioInput
            cs.videoDevice  = videoDevice
            cs.isConfigured = true

            applyCineHDFormat(to: videoDevice)
            applyHEVCCodec(cs: cs)

        } catch {
            Logger.camera.error("Failed to create capture inputs: \(error.localizedDescription, privacy: .public)")
            cs.session.commitConfiguration()
            return
        }

        cs.session.commitConfiguration()
        cs.session.startRunning()
        Logger.camera.notice("Capture session configured and started.")

        // Rotation coordination is set up after commitConfiguration so the
        // movie output's connection already exists.
        setupCaptureRotationCoordinator(cs: cs, device: videoDevice)
        lockHDMIToLandscape(cs: cs)

        DispatchQueue.main.async { [weak self] in
            self?.videoDevice = cs.videoDevice
            self?.isSessionRunning = cs.session.isRunning
        }
    }

    /// Locks the active format to Cine-HD: 1920x1080 @ 30fps. Falls back to
    /// leaving the device's current format untouched if no exact match exists
    /// (all supported back cameras on iOS 18 targets have one).
    nonisolated private func applyCineHDFormat(to device: AVCaptureDevice) {
        let targetFrameRate = 30.0

        let matchingFormat = device.formats.first { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let supportsFrameRate = format.videoSupportedFrameRateRanges.contains { range in
                range.minFrameRate <= targetFrameRate && targetFrameRate <= range.maxFrameRate
            }
            return dimensions.width == 1920 && dimensions.height == 1080 && supportsFrameRate
        }

        guard let format = matchingFormat else {
            Logger.camera.warning("No exact 1920x1080@30 format found on this device; using default format.")
            return
        }

        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
            Logger.camera.info("Applied Cine-HD format: 1920x1080@30.")
        } catch {
            Logger.camera.error("Failed to lock device for Cine-HD format configuration: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Forces H.265/HEVC on the movie output's video connection, falling back
    /// to H.264 only if the device genuinely can't encode HEVC.
    nonisolated private func applyHEVCCodec(cs: CameraSession) {
        guard let connection = cs.movieOutput.connection(with: .video) else { return }
        let availableCodecs = cs.movieOutput.availableVideoCodecTypes
        let codec: AVVideoCodecType = availableCodecs.contains(.hevc) ? .hevc : .h264
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

    nonisolated private func performToggleRecording(cs: CameraSession) {
        guard cs.isConfigured else {
            Logger.recording.error("Session not configured — cannot record.")
            return
        }

        if cs.movieOutput.isRecording {
            Logger.recording.notice("Stopping recording.")
            cs.movieOutput.stopRecording()
            return
        }

        Logger.recording.notice("Starting recording; locking orientation.")
        // Freeze orientation for the duration of the recording — the safety
        // net covering camera preview, recording, and HDMI output together.
        cs.isOrientationLocked = true

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        cs.movieOutput.startRecording(to: outputURL, recordingDelegate: cs)
    }
}
