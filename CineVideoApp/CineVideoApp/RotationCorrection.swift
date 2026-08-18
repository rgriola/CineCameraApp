//
//  RotationCorrection.swift
//  CineVideoApp
//
//  Created by rgriola on 8/18/26.
//

import AVFoundation
import CoreGraphics
import OSLog

/// `AVCaptureDevice.RotationCoordinator` computes the angle needed to keep
/// video upright relative to gravity, but which physical landscape
/// orientation counts as "upright" depends on how the back camera's sensor
/// is mounted — it's a fixed 180° flip from what this app actually wants,
/// specifically for landscape (this app supports only Landscape Right, never
/// Landscape Left, so there's exactly one landscape case to correct).
///
/// Portrait angles (0°/180°) are untouched — only the landscape angles
/// (90°/270°) are swapped. Applied uniformly everywhere a rotation angle from
/// a `RotationCoordinator` is set on an `AVCaptureConnection`, so the
/// on-device preview, the recorded file, and the HDMI mirror all agree.
extension CGFloat {
    nonisolated var landscapeCorrected: CGFloat {
        switch self {
        case 90: return 270
        case 270: return 90
        default: return self
        }
    }
}

extension AVCaptureDevice {
    /// Compact, log-friendly summary of this device's position and active
    /// format (e.g. "back 1920x1080@30"), so rotation-angle log lines make it
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
    /// Applies a raw `RotationCoordinator` angle to this connection, with the
    /// shared landscape correction above, logging whenever the resulting
    /// angle actually changes. `source` identifies which consumer is logging
    /// (e.g. "Preview", "Recording", "HDMI") so Console.app output makes it
    /// obvious which of the three (preview/recording/HDMI) is being updated,
    /// and `device` supplies the camera position + active format for context.
    @discardableResult
    nonisolated func applyRotationAngle(_ rawAngle: CGFloat, source: String, device: AVCaptureDevice?) -> Bool {
        let corrected = rawAngle.landscapeCorrected
        let deviceInfo = device?.loggingDescription ?? "unknown device"
        let connectionID = ObjectIdentifier(self)

        // Unconditional debug-level log on every call — including no-op
        // calls where the angle didn't change — so Console.app shows the
        // full call history for diagnosing "preview didn't rotate" issues,
        // not just the moments a value actually changed.
        Logger.orientation.debug("\(source, privacy: .public) [\(deviceInfo, privacy: .public)] connection=\(String(describing: connectionID), privacy: .public): apply raw \(rawAngle, privacy: .public)° -> corrected \(corrected, privacy: .public)° (current \(self.videoRotationAngle, privacy: .public)°)")

        guard isVideoRotationAngleSupported(corrected) else {
            Logger.orientation.warning("\(source, privacy: .public) [\(deviceInfo, privacy: .public)]: angle \(corrected, privacy: .public)\u{00B0} (raw \(rawAngle, privacy: .public)\u{00B0}) is unsupported; leaving unchanged.")
            return false
        }

        let didChange = videoRotationAngle != corrected
        videoRotationAngle = corrected

        if didChange {
            Logger.orientation.notice("\(source, privacy: .public) [\(deviceInfo, privacy: .public)]: rotation angle set to \(corrected, privacy: .public)\u{00B0} (raw \(rawAngle, privacy: .public)\u{00B0} from RotationCoordinator). Readback: \(self.videoRotationAngle, privacy: .public)°")
        }
        return didChange
    }
}
