//
//  CapturePolicyTests.swift
//  CineVideoAppTests
//
//  Phase 0 of the DI refactor: unit tests for the pure capture *policy*
//  extracted from `CameraManager` — codec selection, Cine-HD format selection,
//  and recording-URL generation. None of these touch real capture hardware.
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

struct CineHDFormatSelectorTests {

    /// Convenience for building 30fps-capable descriptors of a given size.
    private func format(_ width: Int32, _ height: Int32, fps: ClosedRange<Double> = 1...30) -> CaptureFormatDescriptor {
        CaptureFormatDescriptor(width: width, height: height, frameRateRanges: [fps])
    }

    @Test("selects the first exact 1920x1080 format that supports 30fps")
    func selectsExact1080p30() {
        let formats = [format(1280, 720), format(1920, 1080), format(3840, 2160)]
        #expect(CineHDFormatSelector.selectIndex(in: formats, targetFrameRate: 30) == 1)
    }

    @Test("returns the first index when multiple 1080p30 formats exist")
    func returnsFirstOfMultipleMatches() {
        let formats = [format(1920, 1080), format(1920, 1080)]
        #expect(CineHDFormatSelector.selectIndex(in: formats, targetFrameRate: 30) == 0)
    }

    @Test("returns nil when 1080p exists but does not support the target frame rate")
    func nilWhen1080pLacksFrameRate() {
        let formats = [format(1920, 1080, fps: 1...24)]
        #expect(CineHDFormatSelector.selectIndex(in: formats, targetFrameRate: 30) == nil)
    }

    @Test("returns nil when no 1080p format is present")
    func nilWhenNo1080p() {
        let formats = [format(1280, 720), format(3840, 2160)]
        #expect(CineHDFormatSelector.selectIndex(in: formats, targetFrameRate: 30) == nil)
    }

    @Test("returns nil for an empty format list")
    func nilForEmpty() {
        #expect(CineHDFormatSelector.selectIndex(in: [], targetFrameRate: 30) == nil)
    }

    @Test("frame-rate match is inclusive at range boundaries")
    func inclusiveBoundaries() {
        let atMax = [format(1920, 1080, fps: 24...30)]
        #expect(CineHDFormatSelector.selectIndex(in: atMax, targetFrameRate: 30) == 0)
        let atMin = [format(1920, 1080, fps: 30...60)]
        #expect(CineHDFormatSelector.selectIndex(in: atMin, targetFrameRate: 30) == 0)
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
