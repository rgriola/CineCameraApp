import Testing
import CoreGraphics
import UIKit
@testable import CineVideoApp

struct LandscapeControlTests {
    @MainActor
    @Test("Point taps accept only the fitted video, not black bars",
          arguments: [CGSize(width: 835, height: 384), CGSize(width: 393, height: 852),
                      CGSize(width: 1024, height: 768)])
    func previewPointBounds(_ size: CGSize) {
        let image = CameraLayout.previewFrame(containerSize: size, videoDimensions: (1920, 1080)).videoRect
        #expect(FocusPolicy.acceptsPreviewPoint(CGPoint(x: image.midX, y: image.midY), videoRect: image))
        #expect(FocusPolicy.acceptsPreviewPoint(CGPoint(x: image.minX + 0.1, y: image.minY + 0.1), videoRect: image))
        #expect(FocusPolicy.acceptsPreviewPoint(CGPoint(x: image.maxX - 0.1, y: image.maxY - 0.1), videoRect: image))
        for point in [
            CGPoint(x: image.minX - 1, y: image.midY),
            CGPoint(x: image.maxX + 1, y: image.midY),
            CGPoint(x: image.midX, y: image.minY - 1),
            CGPoint(x: image.midX, y: image.maxY + 1),
            CGPoint(x: CGFloat.nan, y: image.midY)
        ] {
            #expect(!FocusPolicy.acceptsPreviewPoint(point, videoRect: image))
        }
        #expect(!FocusPolicy.acceptsPreviewPoint(.zero, videoRect: .zero))
        #expect(!FocusPolicy.acceptsPreviewPoint(.zero, videoRect: .null))
        #expect(!FocusPolicy.acceptsPreviewPoint(.zero, videoRect: .infinite))
    }

    @MainActor
    @Test("Preview taps reject before video is ready")
    func unreadyPreviewPoint() {
        let view = CameraPreview.PreviewUIView(frame: CGRect(x: 0, y: 0, width: 835, height: 384))
        #expect(view.devicePoint(for: CGPoint(x: 417, y: 192)) == nil)
    }

    @Test("Resolution cycling preserves frame rate",
          arguments: CaptureFrameRate.allCases)
    func cycleResolution(_ rate: CaptureFrameRate) {
        let hd = CineFormat(resolution: .hd1080, frameRate: rate)
        #expect(hd.cyclingResolution == CineFormat(resolution: .uhd4K, frameRate: rate))
        #expect(hd.cyclingResolution.cyclingResolution == hd)
    }

    @Test("Frame rate cycling preserves resolution",
          arguments: CaptureResolution.allCases)
    func cycleFrameRate(_ resolution: CaptureResolution) {
        let initial = CineFormat(resolution: resolution, frameRate: .fps24)
        #expect(initial.cyclingFrameRate == CineFormat(resolution: resolution, frameRate: .fps30))
        #expect(initial.cyclingFrameRate.cyclingFrameRate == initial)
    }

    @Test("8 times cap converts to device space", arguments: [CGFloat(0.5), 1, 2])
    func zoomCap(_ multiplier: CGFloat) {
        let maximum = ZoomPolicy.cappedMaximum(deviceMaximum: 100, multiplier: multiplier)
        #expect(ZoomPolicy.displayed(fromDeviceFactor: maximum, multiplier: multiplier) == 8)
        let smaller = ZoomPolicy.cappedMaximum(deviceMaximum: 2, multiplier: multiplier)
        #expect(smaller == 2)
    }

    @Test("Out-of-cap presets are omitted without inventing unavailable lenses")
    func zoomPresets() {
        #expect(ZoomPolicy.presetStops(
            switchOverFactors: [2, 4, 10, 20], multiplier: 0.5, minFactor: 1, maxFactor: 100
        ) == [0.5, 1, 2, 5])
        #expect(ZoomPolicy.presetStops(
            switchOverFactors: [], multiplier: 1, minFactor: 1, maxFactor: 3
        ) == [1])
    }

    @Test("Snapshot exposes capped range and presets")
    func cappedSnapshot() {
        let snapshot = CameraControlSnapshot.make(
            zoomFactor: 2, minZoomFactor: 1, maxZoomFactor: 100,
            switchOverFactors: [2, 4, 20], displayMultiplier: 0.5,
            exposureBias: 0, minExposureBias: -2, maxExposureBias: 2,
            isMultiLensDevice: true, isFocusLocked: false, isFocusSupported: true,
            isExposureLocked: false, isExposureSupported: true
        )
        #expect(snapshot.zoomRangeDisplayed == 0.5...8)
        #expect(snapshot.zoomPresets == [0.5, 1, 2])
    }

    @Test("Combined lock requires intent and both confirmed device modes",
          arguments: [false, true], [false, true])
    func combinedLock(focusLocked: Bool, exposureLocked: Bool) {
        var snapshot = CameraControlSnapshot.placeholder
        snapshot.isFocusLocked = focusLocked
        snapshot.isExposureLocked = exposureLocked
        #expect(!snapshot.isCombinedLocked)
        snapshot.combinedLockRequested = true
        #expect(snapshot.isCombinedLocked == (focusLocked && exposureLocked))
    }

    @Test("Unsupported modes cannot enable the combined lock control")
    func unsupportedLock() {
        var snapshot = CameraControlSnapshot.placeholder
        #expect(!snapshot.supportsCombinedLock)
        snapshot.isFocusSupported = true
        #expect(!snapshot.supportsCombinedLock)
        snapshot.isExposureSupported = true
        #expect(snapshot.supportsCombinedLock)
    }

    @Test("Settled point modes allow another tap; explicit combined lock blocks it")
    func repeatablePointActions() {
        var snapshot = CameraControlSnapshot.placeholder
        #expect(!snapshot.allowsPointActions)
        snapshot.isFocusSupported = true
        snapshot.isExposureSupported = true
        snapshot.isFocusLocked = true
        snapshot.isExposureLocked = true
        #expect(snapshot.allowsPointActions)
        snapshot.combinedLockRequested = true
        #expect(!snapshot.allowsPointActions)
        snapshot.combinedLockRequested = false
        #expect(snapshot.allowsPointActions)
    }

    @MainActor
    @Test("VoiceOver point actions are removed when unavailable or locked")
    func accessiblePointActions() {
        let view = CameraPreview.PreviewUIView(frame: .zero)
        view.pointActionsAllowed = true
        #expect(view.accessibilityCustomActions?.count == 5)
        view.pointActionsAllowed = false
        #expect(view.accessibilityCustomActions?.isEmpty == true)
        view.pointActionsAllowed = true
        #expect(view.accessibilityCustomActions?.count == 5)
    }

    @Test("Elapsed time formatting uses monotonic durations")
    func elapsedTime() {
        #expect(RecordingTime.label(for: .seconds(-1)) == "00:00")
        #expect(RecordingTime.label(for: .milliseconds(999)) == "00:00")
        #expect(RecordingTime.label(for: .seconds(32)) == "00:32")
        #expect(RecordingTime.label(for: .seconds(125)) == "02:05")
        #expect(RecordingTime.label(for: .seconds(3601)) == "01:00:01")
    }

    @MainActor
    @Test("Point requests without a camera reject without success feedback")
    func unavailablePoint() async {
        let manager = CameraManager()
        let accepted = await withCheckedContinuation { continuation in
            manager.focusAndExpose(at: CGPoint(x: 0.5, y: 0.5)) { accepted in
                continuation.resume(returning: accepted)
            }
        }
        #expect(!accepted)
    }
}
