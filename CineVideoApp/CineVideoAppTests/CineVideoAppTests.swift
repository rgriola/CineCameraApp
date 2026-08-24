//
//  CineVideoAppTests.swift
//  CineVideoAppTests
//
//  Created by rgriola on 8/24/26.
//

import Testing
import AVFoundation
import Photos
@testable import CineVideoApp

@MainActor
struct CineVideoAppTests {

    /// Smoke test: confirms the test target can `@testable import` the app
    /// module and that a freshly constructed `CameraManager` starts in the
    /// expected "nothing determined yet" state — not authorized, not denied —
    /// before any permission cascade runs.
    @Test func freshManagerStartsUndetermined() async throws {
        let manager = CameraManager()
        #expect(manager.cameraAuthStatus == .notDetermined)
        #expect(manager.microphoneAuthStatus == .notDetermined)
        #expect(manager.photoLibraryAuthStatus == .notDetermined)
        #expect(!manager.isAuthorized)
        #expect(!manager.permissionsDenied)
    }
}
