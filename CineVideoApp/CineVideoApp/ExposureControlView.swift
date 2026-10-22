//
//  ExposureControlView.swift
//  CineVideoApp
//
//  Exposure control: an EV-bias slider with tick marks and a Reset button
//  (modeled on PromptCam's EVAdjustmentPanel), plus an AE/locked toggle
//  badge (modeled on PromptCam's CameraLockStatusBadgeView). Standalone for
//  Phase 5 of the camera-controls plan; assembled into the camera chrome
//  alongside the other manual controls in Phase 6. Kept independently
//  togglable from focus per the plan (unlike PromptCam, which combines
//  focus and exposure lock into one control). Stays active during
//  recording (D6) — a cine operator rides exposure mid-take.
//

import SwiftUI

struct ExposureControlView: View {
    let cameraManager: CameraManager
    var compact = false

    private var snapshot: CameraControlSnapshot { cameraManager.controls }

    var body: some View {
        VStack(spacing: 8) {
            evSlider
          /*  HStack(spacing: 8) {
            //    resetButton
            //    Spacer()
            //    aeBadge
            }
            */
        }
    }

    // MARK: - EV slider

    private var evSlider: some View {
        // `exposureBiasRange` collapses to a degenerate `0...0` point before
        // the device has configured (`CameraControlSnapshot.placeholder`) —
        // disable rather than present an interactive-looking control that
        // silently does nothing on a VoiceOver swipe. Mirrors
        // `ZoomControlView.slider`'s same guard.
        let range = snapshot.exposureBiasRange
        let isUnavailable = range.lowerBound == range.upperBound
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                // Hidden from VoiceOver rather than left bare: a trait-less
                // "EV" stop right before the slider's own "Exposure bias, …"
                // announcement would be a redundant, non-actionable extra
                // swipe stop (a11y review finding) — the slider's
                // accessibilityLabel already names what this heading names
                // visually.
                Text("EV")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
                Spacer()
                Text(evReadoutText)
                    .font(.caption.monospacedDigit())
                    .accessibilityHidden(true) // already surfaced via the slider's accessibilityValue
            }
            Group {
                let value = Binding(
                    get: { Double(snapshot.exposureBias) },
                    set: { cameraManager.setExposureBias(Float($0)) }
                )
                let bounds = Double(range.lowerBound)...Double(range.upperBound)
                if isUnavailable {
                    // A stepped slider traps when its range is narrower than one step.
                    Slider(value: value, in: bounds)
                } else {
                    Slider(value: value, in: bounds, step: min(0.1, bounds.upperBound - bounds.lowerBound))
                }
            }
            .frame(minHeight: 44)
            .disabled(isUnavailable)
            // "Exposure bias" (not just "Exposure") — the AE/lock badge
            // below is also labeled around the word "Exposure"; VoiceOver
            // and Voice Control need distinct names for two different
            // controls in the same view, or both read/target ambiguously
            // (a11y review finding).
            .accessibilityInfo(
                label: Text("Exposure bias"),
                value: Text(isUnavailable ? "Unavailable" : accessibleEVReadoutText)
            )
            // The system's own slider adjustment gesture already maps to
            // `setExposureBias`'s Binding above; this custom action instead
            // gives VoiceOver a 0.1 EV step size independent of the slider's
            // default swipe increment, mirroring the plan's explicit "sliders
            // get `.accessibilityAdjustableAction`" requirement (Phase 6
            // item 5), applied here since the slider already exists.
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    cameraManager.adjustExposureBias(by: 0.1)
                case .decrement:
                    cameraManager.adjustExposureBias(by: -0.1)
                @unknown default:
                    break
                }
            }
            if !compact {
                tickMarks(range: range)
            }
        }
    }

    private func tickMarks(range: ClosedRange<Float>) -> some View {
        HStack {
            Text(Self.evLabel(for: range.lowerBound))
            Spacer()
            Text(Self.evLabel(for: 0))
            Spacer()
            Text(Self.evLabel(for: range.upperBound))
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true) // redundant with the slider's own min/mid/max semantics
    }

    // MARK: - Reset

    private var resetButton: some View {
        Button {
            cameraManager.resetExposureBias()
        } label: {
            Group {
                if compact {
                    Image(systemName: CameraSymbols.reset).font(.system(size: 20))
                } else {
                    Label("Reset", systemImage: CameraSymbols.reset).font(.caption)
                }
            }
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityInfo(
            label: Text("Reset exposure"),
            hint: Text("Returns exposure bias to neutral, 0 EV.")
        )
    }

    // MARK: - AE / locked badge

    private var isLocked: Bool { snapshot.isExposureLocked }
    private var isSupported: Bool { snapshot.isExposureSupported }

    private var aeBadge: some View {
        Button {
            // Toggle: locked -> re-enable auto; auto -> lock in place.
            cameraManager.setAutoExposure(isLocked)
        } label: {
            Group {
                if compact {
                    Image(systemName: isLocked ? CameraSymbols.locked : CameraSymbols.exposure)
                        .font(.system(size: 20))
                } else {
                    Text(badgeLabel).font(.caption.weight(.semibold))
                }
            }
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(badgeTintColor)
        // No manual `.opacity()` dimming on top of `.disabled()` — see
        // `FocusControlView`'s matching comment: `.bordered` already dims
        // disabled controls on its own, and stacking opacity on a red tint
        // compounds into a low-contrast state that doesn't respond to
        // Increase Contrast (the Phase 4 a11y finding, applied here
        // up front rather than needing a follow-up fix).
        .disabled(!isSupported)
        // "Exposure mode" (not just "Exposure") — distinct from the
        // slider's "Exposure bias" label above; two controls in the same
        // view sharing one accessible name was ambiguous for both VoiceOver
        // and Voice Control (a11y review finding).
        .accessibilityInfo(
            label: Text("Exposure mode"),
            value: Text(badgeAccessibilityValue),
            hint: Text(badgeAccessibilityHint)
        )
    }

    /// Distinct wording per state, not just the tint color — mirrors
    /// `FocusControlView`'s "AF"/"MF"/"N/A" convention.
    private var badgeLabel: String {
        guard isSupported else { return "N/A" }
        return isLocked ? "LOCK" : "AE"
    }

    private var badgeTintColor: Color {
        guard isSupported else { return .red }
        return isLocked ? .yellow : .white
    }

    private var badgeAccessibilityValue: String {
        guard isSupported else { return "Unsupported" }
        return isLocked ? "Locked" : "Auto"
    }

    private var badgeAccessibilityHint: String {
        guard isSupported else { return "This device doesn't support switching exposure modes." }
        return isLocked ? "Double tap to resume auto exposure." : "Double tap to lock exposure in place."
    }

    private var evReadoutText: String { Self.evLabel(for: snapshot.exposureBias) }

    /// VoiceOver string for the current EV value. Separate from the visual
    /// "+1.3"/"-1.3" glyph label, matching `ZoomControlView`'s precedent of
    /// spelling out units explicitly for TTS.
    private var accessibleEVReadoutText: String { "\(evReadoutText) EV" }

    private static func evLabel(for value: Float) -> String {
        let sign = value >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.1f", value))"
    }
}

#Preview {
    ExposureControlView(cameraManager: .shared)
        .padding()
        .background(Color.black)
}
