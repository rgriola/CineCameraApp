//
//  ZoomControlView.swift
//  CineVideoApp
//
//  Zoom control: a lens preset row (for virtual multi-lens devices) plus a
//  continuous slider spanning the device's available zoom range, with a
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
        VStack(spacing: 8) {
            // No `.animation()` here deliberately — unlike FormatControlsView's
            // recording-state opacity transition, this row's appear/disappear
            // has nothing to gate behind `accessibilityReduceMotion`; SwiftUI's
            // default (instant) behavior is already the Reduce-Motion-safe one.
            if snapshot.isMultiLensDevice {
                presetRow
            }
            HStack(spacing: 8) {
                slider
                readout
            }
        }
    }

    private var presetRow: some View {
        // Horizontally scrollable: the preset count (1-3 typically, more on
        // devices with multiple telephoto lenses) and label width both grow
        // with Dynamic Type, and a fixed-width HStack would clip rather than
        // wrap — a ScrollView guarantees every preset stays reachable.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(snapshot.zoomPresets, id: \.self) { preset in
                    presetButton(for: preset)
                }
            }
        }
    }

    private func presetButton(for preset: CGFloat) -> some View {
        let isActive = ZoomPolicy.isPreset(snapshot.zoomDisplayed, closeTo: preset)
        return Button {
            cameraManager.rampZoom(toDisplayed: preset)
        } label: {
            // Bold weight is the non-color cue for "active" — tint alone
            // (yellow vs. white) isn't sufficient for color-vision-deficient
            // users or a washed-out sunlit screen.
            Text(Self.label(for: preset))
                .font(.caption.weight(isActive ? .bold : .semibold))
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(isActive ? .yellow : .white)
        .accessibilityLabel("\(Self.accessibleLabel(for: preset)) zoom")
        .accessibilityAddTraits(isActive ? .isSelected : [])
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
        .frame(minHeight: 44)
        .disabled(isUnavailable)
        .accessibilityLabel("Zoom")
        .accessibilityValue(isUnavailable ? "Unavailable" : accessibleReadoutText)
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
