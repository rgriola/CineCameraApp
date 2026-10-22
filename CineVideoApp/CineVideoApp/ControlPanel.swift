//
//  ControlPanel.swift
//  CineVideoApp
//
//  Reusable dark-glass popup panel container, ported from PromptCam's
//  `Views/Components/StandardPanel.swift`. Used for Phase 6's Format
//  popup (resolution/frame-rate are hard-blocked during recording, D6, so
//  a tap-to-reveal panel fits them — unlike Zoom/Focus/Exposure, which
//  stay docked persistently in the camera chrome since they must remain
//  reachable mid-take).
//

import SwiftUI

/// Dark-glass panel chrome: header (icon + title + close), divider,
/// content, border, shadow, optional auto-dismiss.
struct ControlPanel<Content: View>: View {
    let title: String
    let icon: String
    let autoDismissAfter: TimeInterval?
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.colorSchemeContrast) private var contrast
    @AccessibilityFocusState private var isHeaderFocused: Bool
    @ScaledMetric(relativeTo: .callout) private var headerIconSize: CGFloat = 18
    @ScaledMetric(relativeTo: .callout) private var closeIconSize: CGFloat = 22

    init(
        title: String,
        icon: String,
        autoDismissAfter: TimeInterval? = nil,
        onDismiss: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.autoDismissAfter = autoDismissAfter
        self.onDismiss = onDismiss
        self.content = content
    }

    /// Boosted for Increase Contrast — mobile-a11y-specialist review
    /// finding E: at the base 12%-opacity white, this panel's only visual
    /// edge/divider can wash out against bright live-camera content
    /// showing through the scrim, with no higher-contrast alternative.
    private var borderColor: Color {
        contrast == .increased ? Color.white.opacity(0.4) : Theme.glassBorder
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: headerIconSize, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    // Purely decorative/redundant with `title` — finding F:
                    // without this, VoiceOver announces the SF Symbol's
                    // inferred name (e.g. "film") as an extra, oddly-worded
                    // stop before the title it duplicates.
                    .accessibilityHidden(true)
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                    .accessibilityFocused($isHeaderFocused)
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: CameraSymbols.close)
                        .font(.system(size: closeIconSize))
                        .foregroundStyle(Theme.primaryText)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Close \(title)")
            }
            .padding(.horizontal, Theme.space16)
            .padding(.vertical, Theme.space12)

            Divider()
                .overlay(borderColor)

            content()
                .padding(Theme.space16)
        }
        .background(Theme.bgGrad)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLg))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusLg)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .padding(.horizontal, Theme.space24)
        .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
        .modifier(AutoDismissModifier(duration: autoDismissAfter, onDismiss: onDismiss))
        // Marks this panel as a modal context to VoiceOver/Switch Control
        // (mobile-a11y-specialist review finding B) and gives VoiceOver an
        // explicit two-finger-scrub-equivalent escape action, mirroring
        // what a real `.sheet` provides automatically.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, onDismiss)
        .onAppear { isHeaderFocused = true }
    }
}

private struct AutoDismissModifier: ViewModifier {
    let duration: TimeInterval?
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        if let duration {
            content
                .task {
                    try? await Task.sleep(for: .seconds(duration))
                    guard !Task.isCancelled else { return }
                    onDismiss()
                }
        } else {
            content
        }
    }
}

/// Scrim + tap-outside-to-dismiss + scale/opacity transition wrapper
/// around a `ControlPanel`. Ported from PromptCam's
/// `StandardPanelOverlay`.
struct ControlPanelOverlay<Content: View>: View {
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var scrimColor: Color {
        contrast == .increased ? Color.black.opacity(0.5) : Theme.overlayScrim
    }

    var body: some View {
        ZStack {
            // A plain `Button` (not a `Color` + `.onTapGesture`) so this
            // scrim is itself an accessible, VoiceOver-activatable "Dismiss"
            // element — mobile-a11y-specialist review finding B: a bare
            // `Color` view has no inherent accessibility exposure, leaving
            // VoiceOver users with no "tap outside" escape equivalent.
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                    onDismiss()
                }
            } label: {
                scrimColor.ignoresSafeArea()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Reduce Motion: a scale transition is exactly the category
                // this setting exists to suppress (finding C) — fall back
                // to a plain fade.
                .transition(reduceMotion ? .opacity : .scale(scale: 0.95).combined(with: .opacity))
        }
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        ControlPanelOverlay(onDismiss: {}) {
            ControlPanel(title: "Format", icon: "film", onDismiss: {}) {
                Text("Panel content")
                    .foregroundStyle(.white)
            }
        }
    }
}
