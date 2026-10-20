//
//  CapturePolicyTests.swift
//  CineVideoAppTests
//
//  Phase 0 of the DI refactor: unit tests for the pure capture *policy*
//  extracted from `CameraManager` — codec selection and recording-URL
//  generation. None of these touch real capture hardware. Format-selection
//  coverage (formerly `CineHDFormatSelectorTests`) migrated to the
//  generalized `CaptureFormatSelectorTests` in CameraControlPolicyTests.swift
//  as part of Phase 2 of the camera-controls plan.
//

import Testing
import AVFoundation
import Foundation
@testable import CineVideoApp

struct CodecSelectorTests {

    @Test("prefers HEVC when available")
    func prefersHEVC() {
        #expect(CodecSelector.select(from: [.hevc, .h264]) == .hevc)
        #expect(CodecSelector.select(from: [.h264, .hevc]) == .hevc)
        #expect(CodecSelector.select(from: [.hevc]) == .hevc)
    }

    @Test("falls back to H.264 when HEVC is unavailable")
    func fallsBackToH264() {
        #expect(CodecSelector.select(from: [.h264]) == .h264)
        #expect(CodecSelector.select(from: [.jpeg, .h264]) == .h264)
    }

    @Test("defaults to H.264 for an empty codec list")
    func emptyDefaultsToH264() {
        #expect(CodecSelector.select(from: []) == .h264)
    }
}

struct RecordingURLTests {

    @Test("produces a .mov URL in the temporary directory")
    func movInTempDir() {
        let url = RecordingURL.makeTemporaryMovieURL()
        #expect(url.pathExtension == "mov")
        let tempPath = FileManager.default.temporaryDirectory.standardizedFileURL.path
        #expect(url.deletingLastPathComponent().standardizedFileURL.path == tempPath)
    }

    @Test("produces a unique URL on each call")
    func uniquePerCall() {
        let a = RecordingURL.makeTemporaryMovieURL()
        let b = RecordingURL.makeTemporaryMovieURL()
        #expect(a != b)
    }
}
