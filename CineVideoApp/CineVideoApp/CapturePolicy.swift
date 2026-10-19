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

/// Selects a capture format by resolution and frame rate: the first descriptor
/// whose pixel dimensions match exactly and that supports the target rate.
nonisolated enum CaptureFormatSelector {
    /// Index of the first matching descriptor, or `nil` if none matches — the
    /// caller then leaves the device's current format untouched. `firstIndex`
    /// preserves the device's own format ordering.
    static func selectIndex(
        in formats: [CaptureFormatDescriptor],
        resolution: CaptureResolution,
        frameRate: CaptureFrameRate
    ) -> Int? {
        selectIndex(in: formats, resolution: resolution, frameRate: Double(frameRate.rawValue))
    }

    /// `Double` overload — the path for non-integral rates (29.97) that
    /// `CaptureFrameRate` deliberately can't express, and what the
    /// `CineHDFormatSelector` shim forwards through so its semantics are
    /// preserved exactly.
    static func selectIndex(
        in formats: [CaptureFormatDescriptor],
        resolution: CaptureResolution,
        frameRate: Double
    ) -> Int? {
        let dimensions = resolution.dimensions
        return formats.firstIndex { descriptor in
            descriptor.width == dimensions.width &&
            descriptor.height == dimensions.height &&
            descriptor.supports(frameRate: frameRate)
        }
    }

    /// Highest `CaptureFrameRate` the descriptor supports, or `nil` if it
    /// supports none — lets a format change degrade to a rate the chosen
    /// format can actually sustain instead of being rejected outright.
    static func fallbackFrameRate(for descriptor: CaptureFormatDescriptor) -> CaptureFrameRate? {
        CaptureFrameRate.allCases
            .sorted { $0.rawValue > $1.rawValue }
            .first { descriptor.supports(frameRate: Double($0.rawValue)) }
    }
}

/// Cine-HD (1920x1080) selection. Retained as a thin shim over
/// `CaptureFormatSelector` so the existing `applyCineHDFormat` call site and
/// its tests keep working unchanged until Phase 2 migrates them.
nonisolated enum CineHDFormatSelector {
    /// Index of the first matching descriptor, or `nil` if none matches — the
    /// caller then leaves the device's default format untouched.
    static func selectIndex(
        in formats: [CaptureFormatDescriptor],
        targetFrameRate: Double
    ) -> Int? {
        CaptureFormatSelector.selectIndex(
            in: formats, resolution: .hd1080, frameRate: targetFrameRate
        )
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
