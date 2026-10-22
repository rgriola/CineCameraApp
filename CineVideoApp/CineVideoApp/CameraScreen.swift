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
//  Portrait controls anchor to the safe top and bottom edges, independently
//  of the video's letterbox axis. Zoom sits above a fixed Record row.
//  LandscapeCameraChrome supplies the separate landscape overlay.
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
    @State private var landscapePanel: LandscapeCameraChrome.Panel?
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
            let insets = proxy.safeAreaInsets

            CameraPreview(session: cameraManager.session, cameraManager: cameraManager)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(landscapePanel != nil || activePanel != nil)
                .allowsHitTesting(landscapePanel == nil && activePanel == nil)
                .ignoresSafeArea()
                .overlay(alignment: .top) {
                    if proxy.size.height >= proxy.size.width {
                        formatDock
                            .padding(.top, edgeGap(insets.top))
                            .frame(maxWidth: .infinity, alignment: .top)
                            .accessibilityHidden(activePanel != nil)
                            .allowsHitTesting(activePanel == nil)
                    }
                }
                .overlay(alignment: .bottom) {
                    if proxy.size.height >= proxy.size.width {
                        primaryDock
                            .padding(.bottom, edgeGap(insets.bottom))
                            .frame(maxWidth: .infinity, alignment: .bottom)
                            .accessibilityHidden(activePanel != nil)
                            .allowsHitTesting(activePanel == nil)
                    }
                }
                .overlay {
                    if proxy.size.width > proxy.size.height {
                        LandscapeCameraChrome(cameraManager: cameraManager, panel: $landscapePanel)
                    }
                }
                .overlay {
                    switch activePanel {
                    case .format:
                        ControlPanelOverlay(onDismiss: dismissPanel) {
                            ControlPanel(title: "Format", icon: CameraSymbols.format, onDismiss: dismissPanel) {
                                FormatControlsView(cameraManager: cameraManager)
                            }
                        }
                    case .exposure:
                        ControlPanelOverlay(onDismiss: dismissPanel) {
                            ControlPanel(title: "Exposure", icon: CameraSymbols.exposure, onDismiss: dismissPanel) {
                                ExposureControlView(
                                    cameraManager: cameraManager,
                                    compact: dynamicTypeSize.isAccessibilitySize
                                )
                            }
                        }
                    case nil:
                        EmptyView()
                    }
                }
                .onChange(of: proxy.size.width > proxy.size.height) { _, _ in
                    activePanel = nil
                    landscapePanel = nil
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

    /// The gap between a screen edge and a docked control, guaranteed to
    /// clear that edge's real safe-area inset (notch/Dynamic
    /// Island/home indicator) with a small additional breathing margin.
    private func edgeGap(_ safeAreaInset: CGFloat) -> CGFloat {
        max(
            CameraLayout.Chrome.dockPadding,
            safeAreaInset + CameraLayout.Chrome.dockPadding / 2
            )
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
        .disabled(cameraManager.isOrientationLocked)
        .accessibilityInfo(
            label: Text("Recording format"),
            value: Text(formatLabel),
            hint: Text(cameraManager.isOrientationLocked
                ? "Format controls are unavailable until recording finishes."
                : "Opens recording format and frame rate controls.")
        )
        .accessibilityFocused($focusedTarget, equals: .formatTrigger)
    }

    // MARK: - Primary dock (record cluster + persistent controls)

    private var primaryDock: some View {
        VStack(spacing: CameraLayout.Chrome.dockSpacing) {
            ZoomControlView(cameraManager: cameraManager)
            HStack(spacing: 8) {
                FocusControlView(cameraManager: cameraManager)
                Spacer(minLength: 0)
                recordButton.frame(width: 64, height: 64)
                Spacer(minLength: 0)
                exposureBadge
                exposureBiasButton
            }
            .buttonStyle(.plain)
            .frame(minHeight: 64)
        }
        .padding(.horizontal, CameraLayout.Chrome.dockPadding)
    }

    private var recordButton: some View {
        Button {
            cameraManager.toggleRecording()
        } label: {
            Image(systemName: cameraManager.isRecording ? CameraSymbols.stop : CameraSymbols.record)
                .font(.system(size: 56))
                .foregroundStyle(cameraManager.isRecording ? .red : .white)
        }
        .disabled(!cameraManager.isSessionRunning || cameraManager.recordingPhase.isTransitioning)
        .accessibilityInfo(
            label: Text(cameraManager.isRecording ? "Stop recording" : "Start recording"),
            value: Text(cameraManager.recordingPhase == .starting ? "Starting recording"
                : cameraManager.recordingPhase == .stopping ? "Finishing recording" : "")
        )
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
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: isLocked ? CameraSymbols.locked : CameraSymbols.exposure)
                        .font(.system(size: 20))
                } else {
                    Text(isSupported ? (isLocked ? "LOCK" : "AE") : "N/A")
                        .font(.caption.weight(.semibold))
                }
            }
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .tint(isSupported ? (isLocked ? .yellow : .white) : .red)
        .disabled(!isSupported)
        .accessibilityInfo(
            label: Text("Exposure mode"),
            value: Text(isSupported ? (isLocked ? "Locked" : "Auto") : "Unsupported"),
            hint: Text(isSupported
                ? (isLocked ? "Double tap to resume auto exposure." : "Double tap to lock exposure in place.")
                : "This device doesn't support switching exposure modes.")
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
            Image(systemName: CameraSymbols.sliders)
                .font(.system(size: 15, weight: .semibold))
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .tint(.white)
        .accessibilityInfo(
            label: Text("Adjust exposure bias"),
            hint: Text("Opens the exposure bias slider.")
        )
        .accessibilityFocused($focusedTarget, equals: .exposureTrigger)
    }

    private func openExposurePanel() {
        withAnimation(panelAnimation) { activePanel = .exposure }
    }
}

#Preview {
    CameraScreen(cameraManager: .shared)
}