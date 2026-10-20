//
//  ControlPolicy.swift
//  CineVideoApp
//
//  Pure zoom and exposure math, extracted so it can be unit-tested with no
//  real `AVCaptureDevice`. `nonisolated` for the same reason as
//  `CapturePolicy.swift`: the capture code calls these from `sessionQueue`.
//
//  ZOOM COORDINATE SPACES — the reason this file exists:
//    • device space  — AVFoundation's raw `videoZoomFactor`. On a virtual
//      multi-lens device, device factor 1.0 is the ULTRA-WIDE lens, which the
//      user sees as "0.5×". Everything AVFoundation hands us is device space:
//      `minAvailableVideoZoomFactor`, `maxAvailableVideoZoomFactor`, and
//      `virtualDeviceSwitchOverVideoZoomFactors`.
//    • display space — the user-facing number: device factor multiplied by
//      `AVCaptureDevice.displayVideoZoomFactorMultiplier` (iOS 18+).
//    • the 1× anchor is therefore device factor `1.0 / multiplier`.
//  Every API below names which space each value is in. Mixing them up is the
//  single easiest way to ship a camera that silently starts at 0.5×.
//

import CoreGraphics
import Foundation

nonisolated enum ZoomPolicy {

    /// Device space → display space.
    ///
    /// A non-finite or non-positive `multiplier` is treated as identity rather
    /// than propagated: a misbehaving device must never inject NaN into a
    /// value that later reaches `videoZoomFactor`.
    static func displayed(fromDeviceFactor deviceFactor: CGFloat, multiplier: CGFloat) -> CGFloat {
        guard multiplier.isFinite, multiplier > 0 else { return deviceFactor }
        return deviceFactor * multiplier
    }

    /// Display space → device space. The same identity fallback doubles as the
    /// divide-by-zero guard.
    static func deviceFactor(fromDisplayed displayed: CGFloat, multiplier: CGFloat) -> CGFloat {
        guard multiplier.isFinite, multiplier > 0 else { return displayed }
        return displayed / multiplier
    }

    /// Clamps a DEVICE-space factor into the device's available range.
    /// NaN collapses to the lower bound instead of propagating; infinities pin
    /// to the bounds naturally.
    static func clamp(_ deviceFactor: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        guard lower <= upper else { return lower }
        guard !deviceFactor.isNaN else { return lower }
        return Swift.min(Swift.max(deviceFactor, lower), upper)
    }

    /// User-facing lens stops, DISPLAY space, ascending.
    ///
    /// All three numeric inputs are DEVICE space, taken straight off the
    /// device. The stops are the switch-over points, the 1× anchor, and
    /// `minFactor` itself — the widest lens has no switch-over value of its
    /// own, so the range floor is what produces the "0.5×" button. Out-of-range
    /// candidates are dropped rather than pinned, since pinning would
    /// manufacture duplicate stops at the bounds.
    static func presetStops(
        switchOverFactors: [CGFloat],
        multiplier: CGFloat,
        minFactor: CGFloat,
        maxFactor: CGFloat
    ) -> [CGFloat] {
        guard multiplier.isFinite, multiplier > 0,
              minFactor.isFinite, maxFactor.isFinite,
              minFactor <= maxFactor
        else { return [] }

        let anchor1x = deviceFactor(fromDisplayed: 1, multiplier: multiplier)
        let candidates = ([minFactor, anchor1x] + switchOverFactors)
            .filter { $0.isFinite && $0 > 0 && $0 >= minFactor && $0 <= maxFactor }
            .sorted()

        return candidates.reduce(into: [CGFloat]()) { stops, factor in
            let stop = displayed(fromDeviceFactor: factor, multiplier: multiplier)
            // A switch-over frequently lands exactly on the 1× anchor; without
            // this, float noise would render two "1×" buttons.
            if let last = stops.last, abs(stop - last) <= stopEpsilon { return }
            stops.append(stop)
        }
    }

    private static let stopEpsilon: CGFloat = 1e-4

    /// Whether `displayed` is close enough to `preset` to count as "on" that
    /// lens stop, DISPLAY space. Used to highlight the active preset button —
    /// a tolerance is needed because a ramp settling or `displayVideoZoomFactorMultiplier`
    /// rounding rarely lands on the exact floating-point value.
    static func isPreset(_ displayed: CGFloat, closeTo preset: CGFloat, tolerance: CGFloat = 0.05) -> Bool {
        abs(displayed - preset) <= tolerance
    }
}

nonisolated enum ExposurePolicy {
    /// Clamps EV bias to the device's reported `min`/`maxExposureTargetBias`.
    /// NaN collapses to the lower bound rather than reaching
    /// `setExposureTargetBias`.
    static func clampBias(_ value: Float, min lower: Float, max upper: Float) -> Float {
        guard lower <= upper else { return lower }
        guard !value.isNaN else { return lower }
        return Swift.min(Swift.max(value, lower), upper)
    }

    /// Clamps a tap-to-expose point (Phase 5's `exposeAndMeter(at:)`) into the
    /// unit square. `exposurePointOfInterest` documents the exact same
    /// `(0,0)`–`(1,1)` unit square as `focusPointOfInterest`, so this is a
    /// thin alias over `FocusPolicy.clampDevicePoint` rather than a
    /// duplicate implementation — both points come from the same
    /// `PreviewUIView.devicePoint(for:)` conversion.
    static func clampDevicePoint(_ point: CGPoint) -> CGPoint {
        FocusPolicy.clampDevicePoint(point)
    }
}

/// A `Sendable` snapshot of the device-derived control state, built on
/// `sessionQueue` (where the `AVCaptureDevice` is safe to read) and handed to
/// the main actor in one hop. Reading these values directly from the main
/// actor would race `sessionQueue`'s configuration work.
nonisolated struct CameraControlSnapshot: Equatable, Sendable {
    var zoomDisplayed: CGFloat
    var zoomRangeDisplayed: ClosedRange<CGFloat>
    var zoomPresets: [CGFloat]
    var exposureBias: Float
    var exposureBiasRange: ClosedRange<Float>
    var isMultiLensDevice: Bool
    var isFocusLocked: Bool
    var isFocusSupported: Bool
    var isExposureLocked: Bool
    var isExposureSupported: Bool

    /// Pre-device defaults. A degenerate `1...1` zoom range and `0...0` bias
    /// range mean "nothing selectable yet", which is what the UI should show
    /// before the session finishes configuring.
    static let placeholder = CameraControlSnapshot(
        zoomDisplayed: 1,
        zoomRangeDisplayed: 1...1,
        zoomPresets: [],
        exposureBias: 0,
        exposureBiasRange: 0...0,
        isMultiLensDevice: false,
        isFocusLocked: false,
        isFocusSupported: false,
        isExposureLocked: false,
        isExposureSupported: false
    )

    /// Builds a snapshot from raw device readings. Pure, so the range-safety
    /// and conversion behavior is unit-testable without an `AVCaptureDevice`.
    ///
    /// All zoom inputs are DEVICE space (see `ZoomPolicy`); the snapshot's
    /// zoom values are DISPLAY space. Inverted or non-finite bounds are
    /// collapsed rather than passed to `ClosedRange`, which would trap.
    static func make(
        zoomFactor: CGFloat,
        minZoomFactor: CGFloat,
        maxZoomFactor: CGFloat,
        switchOverFactors: [CGFloat],
        displayMultiplier: CGFloat,
        exposureBias: Float,
        minExposureBias: Float,
        maxExposureBias: Float,
        isMultiLensDevice: Bool,
        isFocusLocked: Bool,
        isFocusSupported: Bool,
        isExposureLocked: Bool,
        isExposureSupported: Bool
    ) -> CameraControlSnapshot {
        let lowerDisplayed = ZoomPolicy.displayed(fromDeviceFactor: minZoomFactor, multiplier: displayMultiplier)
        let upperDisplayed = ZoomPolicy.displayed(fromDeviceFactor: maxZoomFactor, multiplier: displayMultiplier)
        let currentDisplayed = ZoomPolicy.displayed(fromDeviceFactor: zoomFactor, multiplier: displayMultiplier)

        let zoomRange = safeRange(lower: lowerDisplayed, upper: upperDisplayed, fallback: 1)
        let biasRange = safeRange(lower: minExposureBias, upper: maxExposureBias, fallback: 0)

        return CameraControlSnapshot(
            zoomDisplayed: ZoomPolicy.clamp(currentDisplayed, min: zoomRange.lowerBound, max: zoomRange.upperBound),
            zoomRangeDisplayed: zoomRange,
            zoomPresets: ZoomPolicy.presetStops(
                switchOverFactors: switchOverFactors,
                multiplier: displayMultiplier,
                minFactor: minZoomFactor,
                maxFactor: maxZoomFactor
            ),
            exposureBias: ExposurePolicy.clampBias(exposureBias, min: biasRange.lowerBound, max: biasRange.upperBound),
            exposureBiasRange: biasRange,
            isMultiLensDevice: isMultiLensDevice,
            isFocusLocked: isFocusLocked,
            isFocusSupported: isFocusSupported,
            isExposureLocked: isExposureLocked,
            isExposureSupported: isExposureSupported
        )
    }

    /// `ClosedRange` traps when `lower > upper`, and propagates NaN silently.
    /// Device-reported bounds are not worth trusting with a crash.
    private static func safeRange<T: BinaryFloatingPoint>(lower: T, upper: T, fallback: T) -> ClosedRange<T> {
        guard lower.isFinite, upper.isFinite else { return fallback...fallback }
        guard lower <= upper else { return lower...lower }
        return lower...upper
    }
}

// ---------------------------------------------------------------------------
// FocusPolicy — pure tap-to-focus point math (Phase 4).
// ---------------------------------------------------------------------------

/// Pure helpers supporting tap-to-focus. The actual layer→device coordinate
/// conversion (D5) can't live here — it requires the live
/// `AVCaptureVideoPreviewLayer` and so stays in
/// `CameraPreview.PreviewUIView.devicePoint(for:)` — but the result of that
/// conversion is defensively re-validated here before it reaches
/// `AVCaptureDevice`.
nonisolated enum FocusPolicy {
    /// Clamps a tap-to-focus point into the unit square `focusPointOfInterest`
    /// documents: `(0,0)` top-left, `(1,1)` bottom-right. `captureDevicePointConverted(fromLayerPoint:)`
    /// is documented to already return a point in this range for taps inside
    /// the preview layer's bounds, but a non-finite value should never reach
    /// `AVCaptureDevice` unchecked — falls back to the center point (0.5, 0.5).
    static func clampDevicePoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: clampUnit(point.x), y: clampUnit(point.y))
    }

    private static func clampUnit(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0), 1)
    }
}
