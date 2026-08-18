//
//  CameraManager.swift
//  CineVideoApp
//
//  Created by rgriola on 8/18/26.
//

@preconcurrency import AVFoundation
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
}

extension CameraSession: AVCaptureFileOutputRecordingDelegate {

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        onRecordingStateChange?(true)
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        // Recording has ended — release the orientation lock and immediately
        // catch the connection up to wherever the device is currently held.
        isOrientationLocked = false
        if let coordinator = captureRotationCoordinator,
           let connection = movieOutput.connection(with: .video) {
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }

        onRecordingStateChange?(false)

        if let error {
            onSaveError?("Recording failed: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: outputFileURL)
            return
        }

        saveToPhotoLibrary(outputFileURL)
    }

    nonisolated private func saveToPhotoLibrary(_ url: URL) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard status == .authorized || status == .limited else {
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
                self?.onSaveError?("Failed to save video: \(error.localizedDescription)")
            } else if !success {
                self?.onSaveError?("Video save did not complete.")
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

    // MARK: - UI state (main actor)
    var isSessionRunning     = false
    var isRecording          = false
    var cameraAuthStatus:       AVAuthorizationStatus = .notDetermined
    var microphoneAuthStatus:   AVAuthorizationStatus = .notDetermined
    var photoLibraryAuthStatus: PHAuthorizationStatus = .notDetermined
    var lastError: String?

    var session: AVCaptureSession { cs.session }

    /// The active video device, exposed so `CameraPreview` can build its own
    /// preview-specific `RotationCoordinator`. Only meaningful once the
    /// session has finished configuring (mirrors how `session` is exposed).
    var videoDevice: AVCaptureDevice? { cs.videoDevice }

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
            checkMicrophonePermission()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.cameraAuthStatus = granted ? .authorized : .denied
                    self?.checkMicrophonePermission()
                }
            }
        case .denied, .restricted:
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

    // MARK: - Permission cascade (main actor)

    private func checkMicrophonePermission() {
        microphoneAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        switch microphoneAuthStatus {
        case .authorized:
            checkPhotoLibraryPermission()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.microphoneAuthStatus = granted ? .authorized : .denied
                    self?.checkPhotoLibraryPermission()
                }
            }
        case .denied, .restricted:
            checkPhotoLibraryPermission()
        @unknown default:
            microphoneAuthStatus = .denied
        }
    }

    private func checkPhotoLibraryPermission() {
        photoLibraryAuthStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)

        switch photoLibraryAuthStatus {
        case .authorized, .limited:
            startSessionIfAuthorized()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
                DispatchQueue.main.async {
                    self?.photoLibraryAuthStatus = status
                    self?.startSessionIfAuthorized()
                }
            }
        case .denied, .restricted:
            break
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
                self?.isSessionRunning = cs.session.isRunning
            }
            return
        }

        cs.session.beginConfiguration()

        guard let videoDevice = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .back)
        else {
            print("Failed to find a video device.")
            cs.session.commitConfiguration()
            return
        }

        guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
            print("Failed to find an audio device.")
            cs.session.commitConfiguration()
            return
        }

        do {
            let videoInput = try AVCaptureDeviceInput(device: videoDevice)
            let audioInput = try AVCaptureDeviceInput(device: audioDevice)

            guard cs.session.canAddInput(videoInput) else {
                print("Cannot add video input.")
                cs.session.commitConfiguration(); return
            }
            guard cs.session.canAddInput(audioInput) else {
                print("Cannot add audio input.")
                cs.session.commitConfiguration(); return
            }
            guard cs.session.canAddOutput(cs.movieOutput) else {
                print("Cannot add movie output.")
                cs.session.commitConfiguration(); return
            }

            cs.session.addInput(videoInput)
            cs.session.addInput(audioInput)
            cs.session.addOutput(cs.movieOutput)

            cs.videoInput   = videoInput
            cs.audioInput   = audioInput
            cs.videoDevice  = videoDevice
            cs.isConfigured = true

            applyCineHDFormat(to: videoDevice)
            applyHEVCCodec(cs: cs)

        } catch {
            print("Failed to create capture inputs: \(error.localizedDescription)")
            cs.session.commitConfiguration()
            return
        }

        cs.session.commitConfiguration()
        cs.session.startRunning()

        // Rotation coordination is set up after commitConfiguration so the
        // movie output's connection already exists.
        setupCaptureRotationCoordinator(cs: cs, device: videoDevice)

        DispatchQueue.main.async { [weak self] in
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
            print("No exact 1920x1080@30 format found on this device; using default format.")
            return
        }

        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
        } catch {
            print("Failed to lock device for Cine-HD format configuration: \(error.localizedDescription)")
        }
    }

    /// Forces H.265/HEVC on the movie output's video connection, falling back
    /// to H.264 only if the device genuinely can't encode HEVC.
    nonisolated private func applyHEVCCodec(cs: CameraSession) {
        guard let connection = cs.movieOutput.connection(with: .video) else { return }
        let availableCodecs = cs.movieOutput.availableVideoCodecTypes
        let codec: AVVideoCodecType = availableCodecs.contains(.hevc) ? .hevc : .h264
        cs.movieOutput.setOutputSettings([AVVideoCodecKey: codec], for: connection)
    }

    /// Wires an `AVCaptureDevice.RotationCoordinator` to the movie output's
    /// connection so recorded video always matches how the device is held,
    /// unless `cs.isOrientationLocked` is set (during an active recording).
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
        guard !cs.isOrientationLocked else { return }
        guard let connection = cs.movieOutput.connection(with: .video),
              connection.isVideoRotationAngleSupported(angle)
        else { return }
        connection.videoRotationAngle = angle
    }

    nonisolated private func performToggleRecording(cs: CameraSession) {
        guard cs.isConfigured else {
            print("Session not configured — cannot record.")
            return
        }

        if cs.movieOutput.isRecording {
            cs.movieOutput.stopRecording()
            return
        }

        // Freeze orientation for the duration of the recording — the safety
        // net covering camera preview, recording, and HDMI output together.
        cs.isOrientationLocked = true

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        cs.movieOutput.startRecording(to: outputURL, recordingDelegate: cs)
    }
}
