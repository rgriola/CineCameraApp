//
//  PermissionCascadeTests.swift
//  CineVideoAppTests
//
//  Phase 1 of the DI refactor: exercises `CameraManager`'s permission cascade
//  through a scripted `PermissionsService` stub — no real prompts, no hardware.
//  Verifies request ordering, that already-granted stages are not re-requested,
//  that the cascade runs every stage even after a denial (so the gate UI
//  reflects all statuses), and the final authorization state.
//

import Testing
import AVFoundation
import Photos
@testable import CineVideoApp

/// Scripted, in-memory `PermissionsService` for tests. Records which requests
/// were issued, in order. Test-target only — never shipped in the app.
@MainActor
final class StubPermissionsService: PermissionsService {
    var cameraStatusValue: AVAuthorizationStatus
    var microphoneStatusValue: AVAuthorizationStatus
    var photoLibraryStatusValue: PHAuthorizationStatus

    /// Results returned from the async request methods (used when the
    /// corresponding status is `.notDetermined`).
    var cameraGrant: Bool
    var microphoneGrant: Bool
    var photoLibraryResult: PHAuthorizationStatus

    /// Names of the requests issued, in call order: "camera", "mic", "photo".
    private(set) var requests: [String] = []

    init(
        camera: AVAuthorizationStatus,
        microphone: AVAuthorizationStatus,
        photoLibrary: PHAuthorizationStatus,
        cameraGrant: Bool = true,
        microphoneGrant: Bool = true,
        photoLibraryResult: PHAuthorizationStatus = .authorized
    ) {
        self.cameraStatusValue = camera
        self.microphoneStatusValue = microphone
        self.photoLibraryStatusValue = photoLibrary
        self.cameraGrant = cameraGrant
        self.microphoneGrant = microphoneGrant
        self.photoLibraryResult = photoLibraryResult
    }

    func cameraStatus() -> AVAuthorizationStatus { cameraStatusValue }
    func requestCamera() async -> Bool { requests.append("camera"); return cameraGrant }

    func microphoneStatus() -> AVAuthorizationStatus { microphoneStatusValue }
    func requestMicrophone() async -> Bool { requests.append("mic"); return microphoneGrant }

    func photoLibraryStatus() -> PHAuthorizationStatus { photoLibraryStatusValue }
    func requestPhotoLibrary() async -> PHAuthorizationStatus { requests.append("photo"); return photoLibraryResult }
}

@MainActor
struct PermissionCascadeTests {

    @Test("requests camera, mic, then photo — in order — when all are undetermined")
    func requestsAllInOrderWhenUndetermined() async {
        let stub = StubPermissionsService(camera: .notDetermined, microphone: .notDetermined, photoLibrary: .notDetermined)
        let manager = CameraManager(permissions: stub)

        await manager.requestAllPermissions()

        #expect(stub.requests == ["camera", "mic", "photo"])
        #expect(manager.isAuthorized)
        #expect(!manager.permissionsDenied)
    }

    @Test("does not re-request stages that are already authorized")
    func skipsAlreadyAuthorizedStages() async {
        let stub = StubPermissionsService(camera: .authorized, microphone: .authorized, photoLibrary: .notDetermined)
        let manager = CameraManager(permissions: stub)

        await manager.requestAllPermissions()

        // Only the undetermined photo stage should have prompted.
        #expect(stub.requests == ["photo"])
        #expect(manager.isAuthorized)
    }

    @Test("does not prompt at all when every permission is already resolved")
    func noPromptsWhenAllResolved() async {
        let stub = StubPermissionsService(camera: .authorized, microphone: .authorized, photoLibrary: .limited)
        let manager = CameraManager(permissions: stub)

        await manager.requestAllPermissions()

        #expect(stub.requests.isEmpty)
        #expect(manager.isAuthorized)   // .limited counts as authorized
    }

    @Test("continues the cascade after a denial so the gate UI reflects every status")
    func cascadeContinuesAfterDenial() async {
        // Camera already denied; mic + photo still undetermined. The cascade
        // must NOT stop at camera — it should still prompt mic and photo.
        let stub = StubPermissionsService(camera: .denied, microphone: .notDetermined, photoLibrary: .notDetermined)
        let manager = CameraManager(permissions: stub)

        await manager.requestAllPermissions()

        #expect(stub.requests == ["mic", "photo"])   // camera not re-requested; cascade continued
        #expect(!manager.isAuthorized)
        #expect(manager.permissionsDenied)
        #expect(manager.cameraAuthStatus == .denied)
        #expect(manager.microphoneAuthStatus == .authorized)
        #expect(manager.photoLibraryAuthStatus == .authorized)
    }

    @Test("a denied request result flips the matching status to denied")
    func deniedRequestResultRecorded() async {
        // Camera prompt is declined by the user (grant = false).
        let stub = StubPermissionsService(
            camera: .notDetermined, microphone: .notDetermined, photoLibrary: .notDetermined,
            cameraGrant: false
        )
        let manager = CameraManager(permissions: stub)

        await manager.requestAllPermissions()

        #expect(manager.cameraAuthStatus == .denied)
        #expect(!manager.isAuthorized)
        #expect(manager.permissionsDenied)
    }

    @Test("photo library request resolving to denied is reflected and blocks authorization")
    func photoDeniedResultBlocksAuthorization() async {
        let stub = StubPermissionsService(
            camera: .authorized, microphone: .authorized, photoLibrary: .notDetermined,
            photoLibraryResult: .denied
        )
        let manager = CameraManager(permissions: stub)

        await manager.requestAllPermissions()

        #expect(stub.requests == ["photo"])
        #expect(manager.photoLibraryAuthStatus == .denied)
        #expect(!manager.isAuthorized)
        #expect(manager.permissionsDenied)
    }

    @Test("restricted camera status is preserved and blocks authorization without a prompt")
    func restrictedCameraPreserved() async {
        let stub = StubPermissionsService(camera: .restricted, microphone: .authorized, photoLibrary: .authorized)
        let manager = CameraManager(permissions: stub)

        await manager.requestAllPermissions()

        #expect(!stub.requests.contains("camera"))
        #expect(manager.cameraAuthStatus == .restricted)
        #expect(!manager.isAuthorized)
        #expect(manager.permissionsDenied)
    }
}
