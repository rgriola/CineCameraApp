//
//  RotationCorrection.swift
//  CineVideoApp
//
//  Created by rgriola on 8/18/26.
//

import CoreGraphics

/// `AVCaptureDevice.RotationCoordinator` computes the angle needed to keep
/// video upright relative to gravity, but which physical landscape
/// orientation counts as "upright" depends on how the back camera's sensor
/// is mounted — it's a fixed 180° flip from what this app actually wants,
/// specifically for landscape (this app supports only Landscape Left, never
/// Landscape Right, so there's exactly one landscape case to correct).
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
