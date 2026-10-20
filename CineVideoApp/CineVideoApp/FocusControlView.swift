//
//  FocusControlView.swift
//  CineVideoApp
//
//  Focus control: an AF/MF toggle badge modeled on PromptCam's
//  CameraLockStatusBadgeView. Standalone for Phase 4 of the camera-controls
//  plan; assembled into the camera chrome alongside the other manual
//  controls in Phase 6. Tap-to-focus itself lives in `CameraPreview` (it's
//  a gesture on the already-live preview, not a deferred control view) —
//  this badge only toggles continuous autofocus vs. a frozen lock. Stays
//  active during recording (D6) — a cine operator racks focus mid-take.
//

import SwiftUI

struct FocusControlView: View {
    let cameraManager: CameraManager

    private var snapshot: CameraControlSnapshot { cameraManager.controls }
    private var isLocked: Bool { snapshot.isFocusLocked }
    private var isSupported: Bool { snapshot.isFocusSupported }

    var body: some View {
        Button {
            // Toggle: locked -> re-enable auto; auto -> lock in place.
            cameraManager.setAutoFocus(isLocked)
        } label: {
            Text(label)
                .font(.caption.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(tintColor)
        // No `.animation()` here deliberately — like ZoomControlView's
        // preset row, this badge's state change has nothing to gate behind
        // `accessibilityReduceMotion`; SwiftUI's default (instant) behavior
        // is already the Reduce-Motion-safe one.
        //
        // No manual `.opacity()` dimming on top of `.disabled()`: `.bordered`
        // already dims disabled controls on its own, and it renders the
        // label text itself in the tint color — stacking a manual opacity
        // on top of the red unsupported tint compounded into a low-contrast
        // red-on-faint-red control that never responded to Increase
        // Contrast (a11y review finding). The "N/A" text plus the system's
        // own disabled treatment is sufficient.
        .disabled(!isSupported)
        .accessibilityLabel("Focus")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(accessibilityHint)
    }

    /// Distinct wording per state, not just the tint color — "N/A" instead
    /// of reusing "AF" with a red tint — so the unsupported state doesn't
    /// rely on color alone to be distinguishable.
    private var label: String {
        guard isSupported else { return "N/A" }
        return isLocked ? "MF" : "AF"
    }

    private var tintColor: Color {
        guard isSupported else { return .red }
        return isLocked ? .yellow : .white
    }

    private var accessibilityValue: String {
        guard isSupported else { return "Unsupported" }
        return isLocked ? "Manual, focus locked" : "Auto"
    }

    private var accessibilityHint: String {
        guard isSupported else { return "This device doesn't support switching focus modes." }
        return isLocked ? "Double tap to resume autofocus." : "Double tap to lock focus in place."
    }
}

#Preview {
    FocusControlView(cameraManager: .shared)
        .padding()
        .background(Color.black)
}
