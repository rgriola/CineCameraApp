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
}
