//
//  CameraScreen.swift
//  CineVideoApp
//
//  Phase 6 of the camera-controls plan: composes the live preview with the
//  Format/Zoom/Focus/Exposure control views, replacing the placeholder
//  `ContentView.cameraView`. Per the user's explicit "hybrid" choice:
//  Zoom/Focus/Exposure-lock stay docked persistently (D6 — they must
//  remain reachable mid-take), while Format (hard-blocked during
//  recording anyway) lives behind a tap-to-reveal `ControlPanel` popup.
//  The fine-grained EV bias slider (a "dial it in" adjustment, not a
//  mid-take reflex like the AE/lock toggle) is likewise behind a popup.
//
//  Chrome is placed using `CameraLayout`'s computed bar *axis* (D7 — top/
//  bottom in portrait, left/right in landscape) so it never covers the
//  live image under ordinary circumstances. Rather than fixing each
//  dock's frame to the geometric bar rect (a first pass of this phase did
//  that, and an on-device-equivalent simulator screenshot pass caught two
//  real bugs that approach produced: the Format pill rendering partly
//  behind the Dynamic Island, and the bottom dock's content silently
//  clipping), docks are anchored to their edge with `.overlay(alignment:)`
//  and nudged clear of the real device safe-area inset (notch/Dynamic
//  Island/home indicator) via `GeometryProxy.safeAreaInsets`. On devices
//  where the letterbox bar is thinner than the safe-area inset plus a
//  dock's natural content size (e.g. a 16:9 format's ~80pt top bar vs. a
//  Pro model's ~59pt Dynamic Island, leaving under 25pt clear), the dock
//  is allowed to dip a small, bounded amount into the live image rather
//  than clip its own content or sit behind the island unreadable — the
//  minimal compromise available given the real screen geometry.
//

import SwiftUI

struct CameraScreen: View {
    let cameraManager: CameraManager

    /// Which popup (if any) is currently presented. A single enum instead
    /// of two independent booleans guarantees mutual exclusion — code
    /// review caught that two separate `@Bool`s let a background panel
    /// request "stick" and pop up unannounced right after the foreground
    /// one was dismissed.
    private enum Panel {
        case format
        case exposure
    }

    /// Which trigger button accessibility focus should return to after a
    /// panel is dismissed — mobile-a11y-specialist review finding A
    /// ("Sheet/dialog dismiss MUST return VoiceOver focus to trigger
    /// element"), since this hand-rolled overlay (not a real `.sheet`)
    /// gets none of that for free.
    private enum FocusTarget: Hashable {
        case formatTrigger
        case exposureTrigger
    }

    @State private var activePanel: Panel?
    @AccessibilityFocusState private var focusedTarget: FocusTarget?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// `nil` under Reduce Motion — matches `FormatControlsView`'s existing
    /// convention for the same animation category (mobile-a11y-specialist
    /// review finding C).
    private var panelAnimation: Animation? {
        reduceMotion ? nil : Theme.panelSpring
    }

    var body: some View {
        GeometryReader { proxy in
            let dimensions = (cameraManager.activeFormat ?? .default).resolution.dimensions
            let frame = CameraLayout.previewFrame(containerSize: proxy.size, videoDimensions: dimensions)
            let insets = proxy.safeAreaInsets

            CameraPreview(session: cameraManager.session, cameraManager: cameraManager)
                .ignoresSafeArea()
                .overlay(alignment: leadingAlignment(for: frame.barAxis)) {
                    formatDock
                        .padding(.top, frame.barAxis == .vertical ? edgeGap(insets.top) : 0)
                        .padding(.leading, frame.barAxis == .horizontal ? edgeGap(insets.leading) : 0)
                        .frame(
                            maxWidth: frame.barAxis == .vertical ? .infinity : nil,
                            maxHeight: frame.barAxis == .horizontal ? .infinity : nil,
                            alignment: leadingAlignment(for: frame.barAxis)
                        )
                        // Hidden (not just visually covered) from VoiceOver/
                        // Switch Control while a popup is modal over it —
                        // code-review + a11y review both caught that an
                        // unhidden background dock stays independently
                        // reachable even behind a popup, including a
                        // same-labeled "Exposure mode" duplicate of the one
                        // inside the Exposure popup.
                        .accessibilityHidden(activePanel != nil)
                        .allowsHitTesting(activePanel == nil)
                }
                .overlay(alignment: primaryAlignment(for: frame.barAxis)) {
                    primaryDock(axis: frame.barAxis)
                        .padding(.bottom, frame.barAxis == .vertical ? edgeGap(insets.bottom) : 0)
                        .padding(.trailing, frame.barAxis == .horizontal ? edgeGap(insets.trailing) : 0)
                        .frame(
                            maxWidth: frame.barAxis == .vertical ? .infinity : nil,
                            maxHeight: frame.barAxis == .horizontal ? .infinity : nil,
                            alignment: primaryAlignment(for: frame.barAxis)
                        )
                        .accessibilityHidden(activePanel != nil)
                        .allowsHitTesting(activePanel == nil)
                }
                .overlay {
                    switch activePanel {
                    case .format:
                        ControlPanelOverlay(onDismiss: dismissPanel) {
                            ControlPanel(title: "Format", icon: "film", onDismiss: dismissPanel) {
                                FormatControlsView(cameraManager: cameraManager)
                            }
                        }
                    case .exposure:
                        ControlPanelOverlay(onDismiss: dismissPanel) {
                            ControlPanel(title: "Exposure", icon: "sun.max", onDismiss: dismissPanel) {
                                ExposureControlView(cameraManager: cameraManager)
                            }
                        }
                    case nil:
                        EmptyView()
                    }
                }
        }
        // The chrome (this screen's own docks *and* every popup, via
        // `Theme`'s dark-only palette) is drawn assuming a dark context —
        // `Text`'s default `.primary`/`.secondary` styles resolve against
        // the system's *actual* light/dark setting, not against whatever
        // custom background color a view happens to sit on, so several
        // labels (e.g. `ZoomControlView`'s readout, `FormatControlsView`'s
        // status pill) rendered as invisible near-black-on-black when the
        // simulator's system appearance was Light — caught via the same
        // screenshot pass that found the Dynamic Island overlap. Matches
        // the conventional dark-chrome treatment of Camera.app and similar
        // viewfinder UIs, which don't follow system appearance either.
        .preferredColorScheme(.dark)
    }

    /// Where the Format dock anchors: the "leading" edge of the bar axis —
    /// top in portrait (`.vertical` bars), left in landscape (`.horizontal`
    /// bars).
    private func leadingAlignment(for axis: CameraLayout.BarAxis) -> Alignment {
        axis == .vertical ? .top : .leading
    }

    /// Where the primary (record cluster) dock anchors: the opposite edge
    /// from `leadingAlignment` — bottom in portrait, right in landscape.
    private func primaryAlignment(for axis: CameraLayout.BarAxis) -> Alignment {
        axis == .vertical ? .bottom : .trailing
    }

    /// The gap between a screen edge and a docked control, guaranteed to
    /// clear that edge's real safe-area inset (notch/Dynamic
    /// Island/home indicator) with a small additional breathing margin.
    private func edgeGap(_ safeAreaInset: CGFloat) -> CGFloat {
        max(CameraLayout.Chrome.dockPadding, safeAreaInset + CameraLayout.Chrome.dockPadding / 2)
    }

    private func dismissPanel() {
        // Return VoiceOver focus to whichever trigger opened the panel
        // that's now closing, before clearing `activePanel` — mobile-a11y-
        // specialist review finding A. A real `.sheet` does this focus
        // restoration automatically; this hand-rolled overlay has to do it
        // explicitly.
        switch activePanel {
        case .format: focusedTarget = .formatTrigger
        case .exposure: focusedTarget = .exposureTrigger
        case nil: break
        }
        withAnimation(panelAnimation) { activePanel = nil }
    }

    // MARK: - Leading dock (Format popup entry point)

    private var formatLabel: String {
        let format = cameraManager.activeFormat ?? .default
        return "\(format.resolution.rawValue) · \(format.frameRate.displayLabel)"
    }

    private var formatDock: some View {
        Button {
            withAnimation(panelAnimation) { activePanel = .format }
        } label: {
            Text(formatLabel)
                .font(.caption.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(.white)
        // D6: format changes are hard-blocked while recording — matches
        // `FormatControlsView`'s own `.disabled(isRecording)` so the entry
        // point itself reflects that instead of opening a panel full of
        // controls that'll immediately reject input.
        .disabled(cameraManager.isRecording)
        .accessibilityLabel("Recording format")
        .accessibilityValue(formatLabel)
        .accessibilityHint("Opens recording format and frame rate controls.")
        .accessibilityFocused($focusedTarget, equals: .formatTrigger)
    }

    // MARK: - Primary dock (record cluster + persistent controls)

    /// `axis` mirrors the bar axis: `.vertical` bars (top/bottom, the
    /// common portrait case) get a horizontal dock row; `.horizontal` bars
    /// (left/right, landscape) get a vertical dock column — the dock's
    /// long axis always runs *along* its bar, never across it.
    ///
    /// At `.accessibility1`+ Dynamic Type sizes, the row/column is wrapped
    /// in a `ScrollView` along that same long axis (mobile-a11y-specialist
    /// review finding D) — mirroring `ZoomControlView.presetRow`'s own
    /// established pattern for the identical reason: at those sizes this
    /// dock's five grouped controls (zoom, record, focus, exposure badge,
    /// exposure-bias shortcut) can't all fit without either overlapping or
    /// silently compressing, and this bar's thickness is computed purely
    /// from video aspect ratio/safe-area insets (`CameraLayout`), not text
    /// metrics.
    private func primaryDock(axis: CameraLayout.BarAxis) -> some View {
        Group {
            switch axis {
            case .vertical:
                let row = HStack(spacing: CameraLayout.Chrome.dockSpacing) {
                    ZoomControlView(cameraManager: cameraManager)
                    Spacer(minLength: 8)
                    recordButton
                    Spacer(minLength: 8)
                    VStack(spacing: 8) {
                        FocusControlView(cameraManager: cameraManager)
                        HStack(spacing: 8) {
                            exposureBadge
                            exposureBiasButton
                        }
                    }
                }
                .padding(.horizontal, CameraLayout.Chrome.dockPadding)

                if dynamicTypeSize >= .accessibility1 {
                    ScrollView(.horizontal, showsIndicators: false) { row }
                } else {
                    row
                }
            case .horizontal:
                let column = VStack(spacing: CameraLayout.Chrome.dockSpacing) {
                    ZoomControlView(cameraManager: cameraManager)
                    Spacer(minLength: 8)
                    recordButton
                    Spacer(minLength: 8)
                    HStack(spacing: 8) {
                        FocusControlView(cameraManager: cameraManager)
                        VStack(spacing: 8) {
                            exposureBadge
                            exposureBiasButton
                        }
                    }
                }
                .padding(.vertical, CameraLayout.Chrome.dockPadding)

                if dynamicTypeSize >= .accessibility1 {
                    ScrollView(.vertical, showsIndicators: false) { column }
                } else {
                    column
                }
            }
        }
    }

    private var recordButton: some View {
        Button {
            cameraManager.toggleRecording()
        } label: {
            Image(systemName: cameraManager.isRecording ? "stop.circle.fill" : "record.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(cameraManager.isRecording ? .red : .white)
        }
        .disabled(!cameraManager.isSessionRunning)
        .accessibilityLabel(cameraManager.isRecording ? "Stop recording" : "Start recording")
    }

    /// Compact, persistent AE/LOCK toggle badge — the exposure control
    /// that needs zero-friction mid-take access (D6). Modeled directly on
    /// `FocusControlView`'s badge (same label/tint/accessibility
    /// conventions) rather than reusing `ExposureControlView` wholesale,
    /// since that view's full EV slider + tick marks + Reset don't fit
    /// this dock's bar budget — that fuller control lives in the popup
    /// opened below instead.
    private var exposureBadge: some View {
        let snapshot = cameraManager.controls
        let isLocked = snapshot.isExposureLocked
        let isSupported = snapshot.isExposureSupported
        return Button {
            cameraManager.setAutoExposure(isLocked)
        } label: {
            Text(isSupported ? (isLocked ? "LOCK" : "AE") : "N/A")
                .font(.caption.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(isSupported ? (isLocked ? .yellow : .white) : .red)
        .disabled(!isSupported)
        .accessibilityLabel("Exposure mode")
        .accessibilityValue(isSupported ? (isLocked ? "Locked" : "Auto") : "Unsupported")
        .accessibilityHint(
            isSupported
                ? (isLocked ? "Double tap to resume auto exposure." : "Double tap to lock exposure in place.")
                : "This device doesn't support switching exposure modes."
        )
        // Redundant VoiceOver-only path to the same popup `exposureBiasButton`
        // opens visually — kept since a VoiceOver user landing on this badge
        // shouldn't have to also discover the separate adjacent button.
        .accessibilityAction(named: "Adjust exposure bias", openExposurePanel)
    }

    /// Separate, full-size affordance that opens the fine EV-bias slider
    /// popup. Previously overlaid on top of `exposureBadge` at a fraction
    /// of the 44×44pt minimum hit target — both code review and
    /// mobile-a11y-specialist review flagged that as too small *and* as
    /// physically overlapping another tappable control, a problem for
    /// Switch Control's point-scanning and Voice Control's name-based
    /// targeting alike. Now a true sibling control instead.
    private var exposureBiasButton: some View {
        Button(action: openExposurePanel) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15, weight: .semibold))
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .accessibilityLabel("Adjust exposure bias")
        .accessibilityHint("Opens the exposure bias slider.")
        .accessibilityFocused($focusedTarget, equals: .exposureTrigger)
    }

    private func openExposurePanel() {
        withAnimation(panelAnimation) { activePanel = .exposure }
    }
}

#Preview {
    CameraScreen(cameraManager: .shared)
}
