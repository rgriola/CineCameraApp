//
//  CameraControlPolicyTests.swift
//  CineVideoAppTests
//
//  Phase 0 of the camera-controls plan: unit tests for the generalized format
//  selector, the format value model, and the pure zoom/exposure math. None of
//  these touch real capture hardware.
//

import Testing
import Foundation
import CoreGraphics
@testable import CineVideoApp

struct CaptureFormatSelectorTests {

    private func format(_ width: Int32, _ height: Int32, fps: ClosedRange<Double> = 1...30) -> CaptureFormatDescriptor {
        CaptureFormatDescriptor(width: width, height: height, frameRateRanges: [fps])
    }

    @Test("selects HD at the requested frame rate")
    func selectsHD() {
        let formats = [format(1280, 720), format(1920, 1080), format(3840, 2160)]
        #expect(CaptureFormatSelector.selectIndex(in: formats, resolution: .hd1080, frameRate: .fps30) == 1)
    }

    @Test("selects 4K, skipping HD entries")
    func selects4K() {
        let formats = [format(1920, 1080), format(3840, 2160, fps: 1...24)]
        #expect(CaptureFormatSelector.selectIndex(in: formats, resolution: .uhd4K, frameRate: .fps24) == 1)
    }

    @Test("returns the first index when multiple matches exist")
    func returnsFirstMatch() {
        let formats = [format(3840, 2160), format(3840, 2160)]
        #expect(CaptureFormatSelector.selectIndex(in: formats, resolution: .uhd4K, frameRate: .fps30) == 0)
    }

    @Test("returns nil when dimensions match but the frame rate is unsupported")
    func nilWhenFrameRateUnsupported() {
        let formats = [format(3840, 2160, fps: 1...24)]
        #expect(CaptureFormatSelector.selectIndex(in: formats, resolution: .uhd4K, frameRate: .fps30) == nil)
    }

    @Test("returns nil when the resolution is absent")
    func nilWhenResolutionAbsent() {
        let formats = [format(1280, 720), format(1920, 1080)]
        #expect(CaptureFormatSelector.selectIndex(in: formats, resolution: .uhd4K, frameRate: .fps30) == nil)
    }

    @Test("returns nil for an empty format list")
    func nilForEmpty() {
        #expect(CaptureFormatSelector.selectIndex(in: [], resolution: .hd1080, frameRate: .fps30) == nil)
    }

    @Test("frame-rate match is inclusive at both range boundaries")
    func inclusiveBoundaries() {
        let atMax = [format(3840, 2160, fps: 24...30)]
        #expect(CaptureFormatSelector.selectIndex(in: atMax, resolution: .uhd4K, frameRate: .fps30) == 0)
        #expect(CaptureFormatSelector.selectIndex(in: atMax, resolution: .uhd4K, frameRate: .fps24) == 0)

        let atMin = [format(1920, 1080, fps: 30...60)]
        #expect(CaptureFormatSelector.selectIndex(in: atMin, resolution: .hd1080, frameRate: .fps30) == 0)
        #expect(CaptureFormatSelector.selectIndex(in: atMin, resolution: .hd1080, frameRate: .fps24) == nil)
    }

    @Test("the CineHD shim matches the generalized selector for HD")
    func shimMatchesGeneralSelector() {
        let formats = [format(1280, 720), format(1920, 1080, fps: 24...30), format(1920, 1080)]
        #expect(
            CineHDFormatSelector.selectIndex(in: formats, targetFrameRate: 30) ==
            CaptureFormatSelector.selectIndex(in: formats, resolution: .hd1080, frameRate: .fps30)
        )
        #expect(
            CineHDFormatSelector.selectIndex(in: formats, targetFrameRate: 24) ==
            CaptureFormatSelector.selectIndex(in: formats, resolution: .hd1080, frameRate: .fps24)
        )
        #expect(CineHDFormatSelector.selectIndex(in: [], targetFrameRate: 30) == nil)
    }

    @Test("the Double overload still matches non-integral rates the enum cannot express")
    func nonIntegralRate() {
        let formats = [format(1920, 1080, fps: 29...30)]
        #expect(CaptureFormatSelector.selectIndex(in: formats, resolution: .hd1080, frameRate: 29.97) == 0)
    }
}

struct CaptureFrameRateFallbackTests {

    private func descriptor(_ ranges: [ClosedRange<Double>]) -> CaptureFormatDescriptor {
        CaptureFormatDescriptor(width: 3840, height: 2160, frameRateRanges: ranges)
    }

    @Test("prefers the highest supported frame rate")
    func prefersHighest() {
        #expect(CaptureFormatSelector.fallbackFrameRate(for: descriptor([1...30])) == .fps30)
        #expect(CaptureFormatSelector.fallbackFrameRate(for: descriptor([24...24, 30...30])) == .fps30)
    }

    @Test("degrades to 24 when only 24 is supported")
    func degradesTo24() {
        #expect(CaptureFormatSelector.fallbackFrameRate(for: descriptor([1...24])) == .fps24)
        #expect(CaptureFormatSelector.fallbackFrameRate(for: descriptor([24...24])) == .fps24)
    }

    @Test("returns nil when no known frame rate is supported")
    func nilWhenNoneSupported() {
        #expect(CaptureFormatSelector.fallbackFrameRate(for: descriptor([60...120])) == nil)
        #expect(CaptureFormatSelector.fallbackFrameRate(for: descriptor([1...23])) == nil)
        #expect(CaptureFormatSelector.fallbackFrameRate(for: descriptor([])) == nil)
    }
}

struct ZoomPolicyConversionTests {

    private func isClose(_ a: CGFloat, _ b: CGFloat, tolerance: CGFloat = 1e-9) -> Bool {
        abs(a - b) <= tolerance
    }

    @Test("displayed and deviceFactor round-trip")
    func roundTrip() {
        for multiplier in [CGFloat(0.5), 1.0, 2.0] {
            for device in [CGFloat(1.0), 2.0, 3.7, 123.0] {
                let displayed = ZoomPolicy.displayed(fromDeviceFactor: device, multiplier: multiplier)
                #expect(isClose(ZoomPolicy.deviceFactor(fromDisplayed: displayed, multiplier: multiplier), device))
            }
        }
    }

    @Test("ultra-wide device factor 1.0 displays as 0.5x, and 1x anchors at 1/multiplier")
    func anchors() {
        #expect(isClose(ZoomPolicy.displayed(fromDeviceFactor: 1.0, multiplier: 0.5), 0.5))
        #expect(isClose(ZoomPolicy.deviceFactor(fromDisplayed: 1.0, multiplier: 0.5), 2.0))
    }

    @Test("a multiplier of 1 is identity")
    func identityMultiplier() {
        #expect(ZoomPolicy.displayed(fromDeviceFactor: 3.0, multiplier: 1.0) == 3.0)
        #expect(ZoomPolicy.deviceFactor(fromDisplayed: 3.0, multiplier: 1.0) == 3.0)
    }

    @Test("an invalid multiplier falls back to identity instead of producing NaN")
    func invalidMultiplierIsIdentity() {
        for bad in [CGFloat(0), -1, .nan, .infinity] {
            #expect(ZoomPolicy.displayed(fromDeviceFactor: 2.0, multiplier: bad) == 2.0)
            #expect(ZoomPolicy.deviceFactor(fromDisplayed: 2.0, multiplier: bad) == 2.0)
        }
    }
}

struct ZoomClampTests {

    @Test("clamps below, within, and above the device range")
    func clampsToRange() {
        #expect(ZoomPolicy.clamp(0.4, min: 1.0, max: 16.0) == 1.0)
        #expect(ZoomPolicy.clamp(4.0, min: 1.0, max: 16.0) == 4.0)
        #expect(ZoomPolicy.clamp(99.0, min: 1.0, max: 16.0) == 16.0)
        #expect(ZoomPolicy.clamp(1.0, min: 1.0, max: 16.0) == 1.0)
        #expect(ZoomPolicy.clamp(16.0, min: 1.0, max: 16.0) == 16.0)
    }

    @Test("non-finite factors collapse to a bound rather than propagating")
    func nonFiniteFactors() {
        #expect(ZoomPolicy.clamp(.nan, min: 1.0, max: 16.0) == 1.0)
        #expect(ZoomPolicy.clamp(.infinity, min: 1.0, max: 16.0) == 16.0)
        #expect(ZoomPolicy.clamp(-.infinity, min: 1.0, max: 16.0) == 1.0)
    }

    @Test("inverted bounds return the lower bound")
    func invertedBounds() {
        #expect(ZoomPolicy.clamp(5.0, min: 16.0, max: 1.0) == 16.0)
    }
}

struct ZoomPresetStopsTests {

    private func isClose(_ a: CGFloat, _ b: CGFloat, tolerance: CGFloat = 1e-6) -> Bool {
        abs(a - b) <= tolerance
    }

    private func matches(_ stops: [CGFloat], _ expected: [CGFloat]) -> Bool {
        stops.count == expected.count && zip(stops, expected).allSatisfy { isClose($0, $1) }
    }

    @Test("single-lens device yields just the 1x stop")
    func singleLens() {
        let stops = ZoomPolicy.presetStops(switchOverFactors: [], multiplier: 1.0, minFactor: 1.0, maxFactor: 16.0)
        #expect(matches(stops, [1.0]))
    }

    @Test("no switchover factors still surfaces the range floor and the 1x anchor")
    func noSwitchoversWithMultiplier() {
        let stops = ZoomPolicy.presetStops(switchOverFactors: [], multiplier: 0.5, minFactor: 1.0, maxFactor: 16.0)
        #expect(matches(stops, [0.5, 1.0]))
    }

    @Test("dual-wide device yields 0.5x and 1x")
    func dualWide() {
        let stops = ZoomPolicy.presetStops(switchOverFactors: [2.0], multiplier: 0.5, minFactor: 1.0, maxFactor: 32.0)
        #expect(matches(stops, [0.5, 1.0]))
    }

    @Test("triple-camera device yields 0.5x, 1x and 3x")
    func tripleCamera() {
        let stops = ZoomPolicy.presetStops(switchOverFactors: [2.0, 6.0], multiplier: 0.5, minFactor: 1.0, maxFactor: 123.0)
        #expect(matches(stops, [0.5, 1.0, 3.0]))
    }

    @Test("stops are ascending and free of duplicates")
    func ascendingAndUnique() {
        let stops = ZoomPolicy.presetStops(switchOverFactors: [2.0, 2.0, 6.0], multiplier: 0.5, minFactor: 1.0, maxFactor: 123.0)
        #expect(stops == stops.sorted())
        #expect(matches(stops, [0.5, 1.0, 3.0]))
    }

    @Test("the 1x anchor is dropped when it falls outside the device range")
    func anchorOutOfRange() {
        let stops = ZoomPolicy.presetStops(switchOverFactors: [], multiplier: 0.5, minFactor: 1.0, maxFactor: 1.5)
        #expect(matches(stops, [0.5]))
    }

    @Test("out-of-range switchover factors are dropped, not pinned")
    func dropsOutOfRangeSwitchovers() {
        let stops = ZoomPolicy.presetStops(switchOverFactors: [2.0, 6.0], multiplier: 0.5, minFactor: 1.0, maxFactor: 4.0)
        #expect(matches(stops, [0.5, 1.0]))
    }

    @Test("invalid inputs yield no stops")
    func invalidInputs() {
        #expect(ZoomPolicy.presetStops(switchOverFactors: [2.0], multiplier: 0, minFactor: 1.0, maxFactor: 16.0).isEmpty)
        #expect(ZoomPolicy.presetStops(switchOverFactors: [2.0], multiplier: .nan, minFactor: 1.0, maxFactor: 16.0).isEmpty)
        #expect(ZoomPolicy.presetStops(switchOverFactors: [2.0], multiplier: 0.5, minFactor: 16.0, maxFactor: 1.0).isEmpty)
        #expect(ZoomPolicy.presetStops(switchOverFactors: [2.0], multiplier: 0.5, minFactor: 1.0, maxFactor: .nan).isEmpty)
    }
}

struct ExposurePolicyTests {

    @Test("clamps bias below, within, and above the device range")
    func clampsToRange() {
        #expect(ExposurePolicy.clampBias(-12, min: -8, max: 8) == -8)
        #expect(ExposurePolicy.clampBias(0, min: -8, max: 8) == 0)
        #expect(ExposurePolicy.clampBias(2.5, min: -8, max: 8) == 2.5)
        #expect(ExposurePolicy.clampBias(12, min: -8, max: 8) == 8)
        #expect(ExposurePolicy.clampBias(-8, min: -8, max: 8) == -8)
        #expect(ExposurePolicy.clampBias(8, min: -8, max: 8) == 8)
    }

    @Test("NaN collapses to the lower bound")
    func nanCollapses() {
        #expect(ExposurePolicy.clampBias(.nan, min: -8, max: 8) == -8)
    }

    @Test("infinities pin to the bounds")
    func infinitiesPin() {
        #expect(ExposurePolicy.clampBias(.infinity, min: -8, max: 8) == 8)
        #expect(ExposurePolicy.clampBias(-.infinity, min: -8, max: 8) == -8)
    }

    @Test("inverted bounds return the lower bound")
    func invertedBounds() {
        #expect(ExposurePolicy.clampBias(0, min: 8, max: -8) == 8)
    }
}

struct CineFormatTests {

    @Test("the default format is HD at 30p")
    func defaultIsHD30() {
        #expect(CineFormat.default.resolution == .hd1080)
        #expect(CineFormat.default.frameRate == .fps30)
    }

    @Test("raw values are the persisted representation")
    func rawValues() {
        #expect(CaptureResolution.hd1080.rawValue == "HD")
        #expect(CaptureResolution.uhd4K.rawValue == "4K")
        #expect(CaptureFrameRate.fps24.rawValue == 24)
        #expect(CaptureFrameRate.fps30.rawValue == 30)
        #expect(CaptureResolution(rawValue: "4K") == .uhd4K)
        #expect(CaptureFrameRate(rawValue: 24) == .fps24)
        #expect(CaptureFrameRate(rawValue: 60) == nil)
    }

    @Test("exposes pixel dimensions and labels")
    func dimensionsAndLabels() {
        #expect(CaptureResolution.hd1080.dimensions.width == 1920)
        #expect(CaptureResolution.hd1080.dimensions.height == 1080)
        #expect(CaptureResolution.uhd4K.dimensions.width == 3840)
        #expect(CaptureResolution.uhd4K.dimensions.height == 2160)
        #expect(CaptureResolution.hd1080.dimensionLabel == "1920×1080")
        #expect(CaptureResolution.uhd4K.dimensionLabel == "3840×2160")
        #expect(CaptureFrameRate.fps24.displayLabel == "24p")
        #expect(CaptureFrameRate.fps30.displayLabel == "30p")
    }

    @Test("only 24p and 30p are offered")
    func casesAreExhaustive() {
        #expect(CaptureResolution.allCases.count == 2)
        #expect(CaptureFrameRate.allCases == [.fps24, .fps30])
    }

    @Test("survives a Codable round-trip")
    func codableRoundTrip() throws {
        for format in [CineFormat.default, CineFormat(resolution: .uhd4K, frameRate: .fps24)] {
            let data = try JSONEncoder().encode(format)
            #expect(try JSONDecoder().decode(CineFormat.self, from: data) == format)
        }
    }

    @Test("storage keys are stable")
    func storageKeys() {
        #expect(CineFormat.StorageKey.resolution == "cineFormat.resolution")
        #expect(CineFormat.StorageKey.frameRate == "cineFormat.frameRate")
    }
}
