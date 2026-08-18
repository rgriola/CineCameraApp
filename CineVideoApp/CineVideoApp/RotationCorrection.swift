//
//  RotationCorrection.swift
//  CineVideoApp
//
//  Created by rgriola on 8/18/26.
//

import AVFoundation
import OSLog

/// TEMPORARY BASELINE (branch `fix/horizontal-preview`): camera preview,
/// recording, and HDMI mirror are all hardcoded to Landscape Right (device
/// held upright, USB‑C/Lightning port on the right) rather than dynamically
/// tracking device rotation.
///
/// `AVCaptureDevice.RotationCoordinator` + `videoRotationAngle` (the modern,
/// non-deprecated rotation API) computes an angle relative to gravity, but
/// which physical landscape orientation counts as "upright" depends on the
/// back camera sensor's mounting — on this device that produced a
/// 180°-flipped image for landscape, and guessing the correct raw angle
/// constant without physical hardware to test against isn't reliable.
///
/// Deliberately sidestepping that guesswork: `AVCaptureConnection.videoOrientation`
/// (deprecated since iOS 17 in favor of `videoRotationAngle`, but still fully
/// functional through iOS 18 — only emits a compiler deprecation warning)
/// accepts the self-documenting `AVCaptureVideoOrientation.landscapeRight`
/// case directly, with zero numeric ambiguity. Once this baseline is
/// confirmed correct on-device, this can be revisited to restore live,
/// rotation-coordinator-driven tracking for Portrait as well.
extension AVCaptureDevice {
    /// Compact, log-friendly summary of this device's position and active
    /// format (e.g. "back 1920x1080@30"), so orientation log lines make it
    /// obvious which camera/format was active at the time.
    nonisolated var loggingDescription: String {
        let positionText: String
        switch position {
        case .back: positionText = "back"
        case .front: positionText = "front"
        case .unspecified: positionText = "unspecified"
        @unknown default: positionText = "unknown"
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(activeFormat.formatDescription)
        let duration = activeVideoMinFrameDuration
        let frameRate = duration.value > 0 ? Double(duration.timescale) / Double(duration.value) : 0
        return "\(positionText) \(dimensions.width)x\(dimensions.height)@\(Int(frameRate))"
    }
}

extension AVCaptureConnection {
    /// Hardcodes this connection to Landscape Right, logging whenever the
    /// resulting orientation actually changes. `source` identifies which
    /// consumer is logging (e.g. "Preview", "Recording", "HDMI") so
    /// Console.app output makes it obvious which of the three is being
    /// updated, and `device` supplies the camera position + active format
    /// for context.
    ///
    /// Intentionally calls the deprecated `videoOrientation` API (see the
    /// type-level comment above) — Swift has no way to silence a deprecation
    /// warning without also deprecating this wrapper itself (which would
    /// just push the same warning out to every call site instead), so the
    /// warnings below are expected and contained to this one function.
    @discardableResult
    nonisolated func applyHardcodedLandscapeRight(source: String, device: AVCaptureDevice?) -> Bool {
        let deviceInfo = device?.loggingDescription ?? "unknown device"

        guard isVideoOrientationSupported else {
            Logger.orientation.warning("\(source, privacy: .public) [\(deviceInfo, privacy: .public)]: landscapeRight is unsupported on this connection.")
            return false
        }

        let didChange = videoOrientation != .landscapeRight
        videoOrientation = .landscapeRight

        if didChange {
            Logger.orientation.notice("\(source, privacy: .public) [\(deviceInfo, privacy: .public)]: orientation hardcoded to landscapeRight.")
        }
        return didChange
    }
}
