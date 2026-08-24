//
//  PermissionGatingTests.swift
//  CineVideoAppTests
//
//  Verifies the pure permission-gating logic on `CameraManager` — the two
//  computed properties that decide whether the app shows the live camera UI
//  (`isAuthorized`) or the permission gate / "open Settings" prompt
//  (`permissionsDenied`). This is business-critical: wrong logic here means the
//  app either never starts capture or starts it without required permissions.
//
//  These are the app's most valuable *unit*-testable surface. The rest of
//  `CameraManager` is AVFoundation session orchestration bound to real capture
//  hardware, which needs a dependency-injection seam (protocol-wrapping the
//  capture stack) before it can be meaningfully unit tested.
//

import Testing
import AVFoundation
import Photos
@testable import CineVideoApp

// `@MainActor` because `CameraManager` is a MainActor-isolated `@Observable`
// type. Each test builds its own fresh `CameraManager` instance (never the
// `.shared` singleton) so scenarios stay deterministic and isolated from
// whatever the test host app's own shared instance is doing.
@MainActor
struct PermissionGatingTests {

    /// One row of the gating truth table: the three input permission states
    /// plus the two expected outputs. Carrying both expectations lets the
    /// `isAuthorized` and `permissionsDenied` tests share a single scenario set.
    struct Scenario: Sendable, CustomTestStringConvertible {
        let name: String
        let camera: AVAuthorizationStatus
        let microphone: AVAuthorizationStatus
        let photoLibrary: PHAuthorizationStatus
        let expectedAuthorized: Bool
        let expectedDenied: Bool

        var testDescription: String { name }
    }

    /// Covers the AND logic of `isAuthorized`, the OR logic of
    /// `permissionsDenied`, the `.limited` photo-library special case, and the
    /// `.notDetermined` middle state (neither authorized nor denied).
    static let scenarios: [Scenario] = [
        .init(name: "all authorized",
              camera: .authorized, microphone: .authorized, photoLibrary: .authorized,
              expectedAuthorized: true, expectedDenied: false),
        .init(name: "photo library limited (still authorized)",
              camera: .authorized, microphone: .authorized, photoLibrary: .limited,
              expectedAuthorized: true, expectedDenied: false),

        // Middle state: nothing granted yet, nothing denied — the app should
        // neither show the camera nor the "denied / open Settings" path.
        .init(name: "all not determined",
              camera: .notDetermined, microphone: .notDetermined, photoLibrary: .notDetermined,
              expectedAuthorized: false, expectedDenied: false),
        .init(name: "camera+mic authorized, photo not determined",
              camera: .authorized, microphone: .authorized, photoLibrary: .notDetermined,
              expectedAuthorized: false, expectedDenied: false),
        .init(name: "camera authorized, mic not determined, photo authorized",
              camera: .authorized, microphone: .notDetermined, photoLibrary: .authorized,
              expectedAuthorized: false, expectedDenied: false),

        // Any single denial/restriction flips `permissionsDenied` true and
        // `isAuthorized` false.
        .init(name: "camera denied",
              camera: .denied, microphone: .authorized, photoLibrary: .authorized,
              expectedAuthorized: false, expectedDenied: true),
        .init(name: "camera restricted",
              camera: .restricted, microphone: .authorized, photoLibrary: .authorized,
              expectedAuthorized: false, expectedDenied: true),
        .init(name: "microphone denied",
              camera: .authorized, microphone: .denied, photoLibrary: .authorized,
              expectedAuthorized: false, expectedDenied: true),
        .init(name: "microphone restricted",
              camera: .authorized, microphone: .restricted, photoLibrary: .authorized,
              expectedAuthorized: false, expectedDenied: true),
        .init(name: "photo library denied",
              camera: .authorized, microphone: .authorized, photoLibrary: .denied,
              expectedAuthorized: false, expectedDenied: true),
        .init(name: "photo library restricted",
              camera: .authorized, microphone: .authorized, photoLibrary: .restricted,
              expectedAuthorized: false, expectedDenied: true),
    ]

    private func makeManager(_ scenario: Scenario) -> CameraManager {
        let manager = CameraManager()
        manager.cameraAuthStatus = scenario.camera
        manager.microphoneAuthStatus = scenario.microphone
        manager.photoLibraryAuthStatus = scenario.photoLibrary
        return manager
    }

    @Test("isAuthorized is true only when camera + mic are authorized and photo is authorized/limited",
          arguments: scenarios)
    func authorizationGate(_ scenario: Scenario) {
        let manager = makeManager(scenario)
        #expect(manager.isAuthorized == scenario.expectedAuthorized)
    }

    @Test("permissionsDenied is true when any permission is denied or restricted",
          arguments: scenarios)
    func deniedGate(_ scenario: Scenario) {
        let manager = makeManager(scenario)
        #expect(manager.permissionsDenied == scenario.expectedDenied)
    }

    /// `isAuthorized` and `permissionsDenied` are never both true — a permission
    /// set can't simultaneously satisfy full authorization and contain a denial.
    @Test("authorized and denied are mutually exclusive", arguments: scenarios)
    func gatesAreMutuallyExclusive(_ scenario: Scenario) {
        let manager = makeManager(scenario)
        #expect(!(manager.isAuthorized && manager.permissionsDenied))
    }
}
