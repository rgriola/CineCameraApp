//
//  ZoomControlView.swift
//  CineVideoApp
//
//  Zoom control: a continuous slider spanning the device's available zoom range, with a
//  live readout. Standalone for Phase 3 of the camera-controls plan;
//  assembled into the camera chrome alongside the other manual controls in
//  Phase 6. Unlike `FormatControlsView`, this control stays active during
//  recording (D6) — a cine operator pulls zoom mid-take.
//

import SwiftUI

struct ZoomControlView: View {
    let cameraManager: CameraManager

    private var snapshot: CameraControlSnapshot { cameraManager.controls }

    var body: some View {
        HStack(spacing: 8) {
            slider
            readout
        }
    }

    private var slider: some View {
        // `zoomRangeDisplayed` collapses to a degenerate `1...1` point before
        // the device has configured (`CameraControlSnapshot.placeholder`) —
        // disable rather than present an interactive-looking control that
        // silently does nothing on a VoiceOver swipe.
        let isUnavailable = snapshot.zoomRangeDisplayed.lowerBound == snapshot.zoomRangeDisplayed.upperBound
        return Slider(
            value: Binding(
                get: { snapshot.zoomDisplayed },
                set: { cameraManager.setZoom(displayed: $0) }
            ),
            in: snapshot.zoomRangeDisplayed
        )
        .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
        .disabled(isUnavailable)
        .accessibilityInfo(
            label: Text("Zoom"),
            value: Text(isUnavailable ? "Unavailable" : accessibleReadoutText)
        )
    }

    private var readout: some View {
        Text(readoutText)
            .font(.caption.monospacedDigit())
            .frame(minWidth: 44)
            .accessibilityHidden(true) // already surfaced via the slider's accessibilityValue
    }

    private var readoutText: String { Self.label(for: snapshot.zoomDisplayed) }

    /// VoiceOver string for the current zoom value. Separate from the
    /// visual `×` glyph label — TTS pronunciation of `×` isn't guaranteed
    /// consistent across locales/synthesizer versions, so accessibility
    /// strings spell it out explicitly.
    private var accessibleReadoutText: String { Self.accessibleLabel(for: snapshot.zoomDisplayed) }

    private static func label(for value: CGFloat) -> String {
        String(format: "%.1f×", value)
    }

    private static func accessibleLabel(for value: CGFloat) -> String {
        String(format: "%.1f times", value)
    }
}

#Preview {
    ZoomControlView(cameraManager: .shared)
        .padding()
        .background(Color.black)
}
