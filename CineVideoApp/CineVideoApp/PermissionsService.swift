//
//  PermissionsService.swift
//  CineVideoApp
//
//  Phase 1 of the DI refactor: a seam over the camera / microphone / photo
//  library permission APIs. `CameraManager` drives its permission cascade
//  through this protocol instead of calling the static `AVCaptureDevice` /
//  `PHPhotoLibrary` APIs directly, so the cascade's *sequencing* logic can be
//  unit-tested with a scripted stub (in the test target) — no real permission
//  prompts, no hardware.
//
//  Production always uses `SystemPermissionsService`; it is the default
//  initializer argument on `CameraManager`, so `CameraManager.shared` and the
//  external-display scene delegate are unaffected.
//

import AVFoundation
import Photos

/// Reads and requests the three permissions the app needs. Synchronous methods
/// report the current status; `async` methods present the system prompt (when
/// the status is `.notDetermined`) and return the resolved status/grant.
protocol PermissionsService: Sendable {
    func cameraStatus() -> AVAuthorizationStatus
    func requestCamera() async -> Bool

    func microphoneStatus() -> AVAuthorizationStatus
    func requestMicrophone() async -> Bool

    func photoLibraryStatus() -> PHAuthorizationStatus
    func requestPhotoLibrary() async -> PHAuthorizationStatus
}

/// The real, system-backed implementation. Thin pass-through to AVFoundation
/// and Photos; holds no state.
struct SystemPermissionsService: PermissionsService {
    func cameraStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    func requestCamera() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    func microphoneStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func photoLibraryStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .addOnly)
    }

    func requestPhotoLibrary() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }
}
