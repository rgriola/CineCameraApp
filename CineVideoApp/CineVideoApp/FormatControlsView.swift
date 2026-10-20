//
//  FormatControlsView.swift
//  CineVideoApp
//
//  Record-format controls: resolution (HD/4K) and frame rate (24p/30p).
//  Standalone for Phase 2 of the camera-controls plan; assembled into the
//  camera chrome alongside the other manual controls in Phase 6.
//

import SwiftUI

struct FormatControlsView: View {
    let cameraManager: CameraManager

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Falls back to HD/30p before the session has configured a device —
    /// matches `CameraControlSnapshot.placeholder`'s "nothing selectable yet"
    /// convention rather than showing a blank control.
    private var activeResolution: CaptureResolution {
        cameraManager.activeFormat?.resolution ?? .hd1080
    }
    private var activeFrameRate: CaptureFrameRate {
        cameraManager.activeFormat?.frameRate ?? .fps30
    }

    var body: some View {
        VStack(spacing: 8) {
            statusPill
            HStack(spacing: 12) {
                resolutionToggle
                frameRatePicker
            }
        }
        // D6: format changes are hard-blocked while recording, at both the
        // UI and service layer — this is the UI half.
        .disabled(cameraManager.isOrientationLocked)
        .opacity(cameraManager.isOrientationLocked ? 0.3 : 1.0)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: cameraManager.isOrientationLocked)
    }

    private var statusPill: some View {
        Text("\(activeResolution.rawValue) · \(activeFrameRate.displayLabel)")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background {
                // A solid tint floor under the material — `.ultraThinMaterial`
                // alone doesn't guarantee legible contrast against arbitrary
                // live camera content (bright sky, white clothing, etc.).
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule().fill(Color.black.opacity(0.35)))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Current recording format")
            .accessibilityValue("\(activeResolution.rawValue), \(activeFrameRate.displayLabel)")
    }

    /// A toggle button, not a picker — only two states exist, and the user
    /// explicitly asked for a toggle for this control.
    private var resolutionToggle: some View {
        let next: CaptureResolution = activeResolution == .hd1080 ? .uhd4K : .hd1080
        return Button {
            cameraManager.setFormat(CineFormat(resolution: next, frameRate: activeFrameRate))
        } label: {
            Text(activeResolution.rawValue)
                .font(.callout.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Recording resolution")
        .accessibilityValue(activeResolution.rawValue)
        .accessibilityHint(
            cameraManager.isOrientationLocked
                ? "Resolution can't be changed until recording finishes."
                : "Switches to \(next.rawValue) recording"
        )
    }

    private var frameRatePicker: some View {
        Picker(
            "Frame rate",
            selection: Binding(
                get: { activeFrameRate },
                set: { cameraManager.setFormat(CineFormat(resolution: activeResolution, frameRate: $0)) }
            )
        ) {
            ForEach(CaptureFrameRate.allCases, id: \.self) { rate in
                Text(rate.displayLabel).tag(rate)
            }
        }
        .pickerStyle(.segmented)
        // `minHeight: 44` — a segmented control's intrinsic height (~32–36pt)
        // falls under the minimum tap target; `minWidth` (not a fixed width)
        // avoids clipping "24p"/"30p" at larger Dynamic Type sizes.
        .frame(minWidth: 120, minHeight: 44)
        .accessibilityLabel("Frame rate")
        .accessibilityHint(
            cameraManager.isOrientationLocked
                ? "Frame rate can't be changed until recording finishes."
                : "Selects the recording frame rate."
        )
    }
}

#Preview {
    FormatControlsView(cameraManager: .shared)
        .padding()
        .background(Color.black)
}
