//
//  CapturePolicy.swift
//  CineVideoApp
//
//  Pure, hardware-independent capture *policy* — the "which one do we pick"
//  decisions extracted out of `CameraManager`'s AVFoundation methods so they
//  can be unit-tested without a real capture device (see the DI refactor plan,
//  Phase 0). These types hold no AVFoundation object state; they operate purely
//  on value inputs and are marked `nonisolated` so the capture code can call
//  them from `CameraManager`'s `sessionQueue` (a nonisolated context) despite
//  this module's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` default.
//

import AVFoundation
import CoreMedia
import Foundation

/// Chooses the recording video codec. Prefers H.265/HEVC and falls back to
/// H.264 only when the device genuinely can't encode HEVC.
nonisolated enum CodecSelector {
    static func select(from available: [AVVideoCodecType]) -> AVVideoCodecType {
        available.contains(.hevc) ? .hevc : .h264
    }
}

/// Value-typed description of a capture format's pixel dimensions and the frame
/// rates it supports. Production maps each real `AVCaptureDevice.Format` into
/// one of these; tests construct them directly, so the Cine-HD selection logic
/// can be exercised with no real `AVCaptureDevice`.
nonisolated struct CaptureFormatDescriptor: Sendable, Equatable {
    let width: Int32
    let height: Int32
    let frameRateRanges: [ClosedRange<Double>]

    /// True if any of this format's ranges covers `frameRate` (inclusive),
    /// matching AVFoundation's `min <= fps && fps <= max` semantics.
    func supports(frameRate: Double) -> Bool {
        frameRateRanges.contains { $0.contains(frameRate) }
    }
}

/// Selects the Cine-HD capture format: the first 1920x1080 format that supports
/// the target frame rate.
nonisolated enum CineHDFormatSelector {
    /// Index of the first matching descriptor, or `nil` if none matches — the
    /// caller then leaves the device's default format untouched. `firstIndex`
    /// preserves the original `formats.first` selection order.
    static func selectIndex(
        in formats: [CaptureFormatDescriptor],
        targetFrameRate: Double
    ) -> Int? {
        formats.firstIndex { descriptor in
            descriptor.width == 1920 &&
            descriptor.height == 1080 &&
            descriptor.supports(frameRate: targetFrameRate)
        }
    }
}

/// Generates the temporary output URL a recording is written to.
nonisolated enum RecordingURL {
    /// A unique `.mov` URL in the system temporary directory.
    static func makeTemporaryMovieURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
    }
}
