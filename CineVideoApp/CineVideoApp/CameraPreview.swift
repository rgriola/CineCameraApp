//
//  CameraPreview.swift
//  CineVideoApp
//
//  Created by rgriola on 8/18/26.
//

import SwiftUI
import AVFoundation
import OSLog

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let cameraManager: CameraManager

    func makeUIView(context: Context) -> PreviewUIView {
        let view: CameraPreview.PreviewUIView = PreviewUIView()
        cameraManager.cameraPreviewView = view
        view.backgroundColor = .black
        view.setupPreviewLayer(session: session)
        if let device = cameraManager.videoDevice {
            context.coordinator.attach(to: view, device: device)
        }
        // Tap-to-focus-and-expose (Phase 4 + Phase 5, D5). The actual
        // layer→device coordinate conversion happens inside PreviewUIView,
        // which owns the layer — never computed here in SwiftUI. A single
        // tap drives both `CameraManager.focus(at:)` and
        // `exposeAndMeter(at:)` at the same point (matching the stock
        // Camera app's combined AF/AE point tap); the separate AF/MF and
        // AE/locked toggle badges remain independently lockable afterward —
        // only the *tap target point* is shared, not the lock state.
        let tapRecognizer = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        view.addGestureRecognizer(tapRecognizer)
        // VoiceOver equivalent for tap-to-focus-and-expose: a
        // direct-manipulation tap gesture is unreachable once VoiceOver's
        // own touch exploration is running, so `PreviewUIView` exposes
        // discrete focus-and-expose points as accessibility custom actions
        // instead (a11y review finding — the AF/MF toggle alone can't
        // express "focus *here*").
        view.onAccessibilityFocus = { [weak view, weak coordinator = context.coordinator] point in
            guard let view else { return }
            coordinator?.requestPoint(point, in: view)
        }
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        // Re-attach whenever the video device becomes available for the
        // first time, OR if SwiftUI ever swaps in a new PreviewUIView/layer
        // instance underneath us (e.g. across certain relayouts triggered by
        // rotation) — otherwise the Coordinator would keep silently updating
        // a stale, now-invisible layer's connection while the visible one
        // never rotates. `isAttached(to:)` logs when this recovery kicks in.
        if let device = cameraManager.videoDevice, !context.coordinator.isAttached(to: uiView) {
            context.coordinator.attach(to: uiView, device: device)
        }
        context.coordinator.updateLockState(isLocked: cameraManager.isOrientationLocked)
        uiView.pointActionsAllowed = cameraManager.controls.allowsPointActions
        uiView.accessibilityHint = cameraManager.controls.combinedLockRequested
            ? "Focus and exposure are locked. Unlock them to select a point."
            : cameraManager.controls.allowsPointActions
                ? "Offers actions to focus and expose at a specific point in frame."
                : "Point selection is unavailable."
    }

    func makeCoordinator() -> Coordinator {
        // The Coordinator object acts as the intermediary that listens to UIKit events and updates SwiftUI state variables.
        Coordinator(cameraManager: cameraManager)
    }

    // -------------------------------------------------------------------
    // Coordinator owns a preview-specific RotationCoordinator so the
    // on-device preview always matches how the device is held — except
    // while starting/recording/stopping, when CameraManager freezes it.
    // -------------------------------------------------------------------
    @MainActor
    final class Coordinator: NSObject {
        private weak var cameraManager: CameraManager?
        private(set) var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
        private var observation: NSKeyValueObservation?
        private weak var previewLayer: AVCaptureVideoPreviewLayer?
        private weak var device: AVCaptureDevice?
        private var isLocked = false

        init(cameraManager: CameraManager) {
            self.cameraManager = cameraManager
            super.init()
        }

        /// Tap-to-focus-and-expose (Phase 4, D5; extended in Phase 5).
        /// Converts the tap's own view-local point into AVFoundation device
        /// space via the tapped `PreviewUIView` itself — the only thing
        /// that knows the preview layer's actual letterboxed video rect —
        /// then forwards it to both `CameraManager.focus(at:)` and
        /// `exposeAndMeter(at:)`. Shows a brief reticle at the tap's
        /// *layer* point (screen space, not device space) for visual
        /// feedback; the reticle is purely decorative, so `isEnded` guards
        /// against firing twice for begin/end on the same tap.
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let view = gesture.view as? PreviewUIView else { return }
            let layerPoint = gesture.location(in: view)
            guard let devicePoint = view.devicePoint(for: layerPoint) else {
                Logger.orientation.debug("Tap-to-focus skipped: point is outside visible video or preview is not ready.")
                return
            }
            requestPoint(devicePoint, in: view)
        }

        /// Shared by `handleTap` and `PreviewUIView.onAccessibilityFocus`
        /// (the VoiceOver custom-action equivalent, since a direct-manipulation
        /// tap gesture is unreachable while VoiceOver's own touch exploration
        /// is running — a11y review flagged the tap gesture alone as a real
        /// capability loss, not just a presentation difference). Drives both
        /// focus and exposure metering at the same point — matching how the
        /// stock Camera app's AF/AE square behaves on tap — but the AF/MF
        /// and AE/locked toggle badges remain independently lockable
        /// afterward; only the tap *target point* is shared between the two,
        /// never their lock state.
        func requestPoint(_ devicePoint: CGPoint, in view: PreviewUIView) {
            cameraManager?.focusAndExpose(at: devicePoint) { [weak view] accepted in
                guard accepted, let view,
                      let point = view.previewLayer?.layerPointConverted(fromCaptureDevicePoint: devicePoint) else { return }
                view.showFocusReticle(at: point)
            }
        }

        func attach(to view: PreviewUIView, device: AVCaptureDevice) {
            guard let previewLayer = view.previewLayer else {
                Logger.orientation.warning("Preview attach skipped: view has no previewLayer yet.")
                return
            }
            if self.previewLayer != nil, self.previewLayer !== previewLayer {
                Logger.orientation.notice("Preview layer instance changed — reattaching RotationCoordinator.")
            }
            self.previewLayer = previewLayer
            self.device = device

            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            rotationCoordinator = coordinator
            Logger.orientation.notice("Preview RotationCoordinator attached for \(device.loggingDescription, privacy: .public).")
            apply(coordinator.videoRotationAngleForHorizonLevelPreview)

            observation = coordinator.observe(
                \.videoRotationAngleForHorizonLevelPreview, options: [.new]
            ) { [weak self] _, change in
                guard let newAngle = change.newValue else { return }
                Logger.orientation.debug("Preview RotationCoordinator KVO fired: raw \(newAngle, privacy: .public)°")
                Task { @MainActor [weak self] in
                    self?.apply(newAngle)
                }
            }
        }

        /// True once `attach(to:device:)` has bound this coordinator to
        /// `view`'s *current* preview layer instance. Used both to gate the
        /// first-time attach and to detect (and recover from) SwiftUI
        /// swapping in a new `PreviewUIView`/layer across relayouts.
        func isAttached(to view: PreviewUIView) -> Bool {
            rotationCoordinator != nil && previewLayer != nil && previewLayer === view.previewLayer
        }

        /// Called from `updateUIView` on every render so the preview freezes
        /// the instant recording starts, and immediately catches up to the
        /// device's current angle the instant recording stops.
        func updateLockState(isLocked: Bool) {
            let wasLocked = self.isLocked
            self.isLocked = isLocked
            if wasLocked, !isLocked, let coordinator = rotationCoordinator {
                apply(coordinator.videoRotationAngleForHorizonLevelPreview)
            }
        }

        private func apply(_ angle: CGFloat) {
            guard cameraManager?.isOrientationLocked != true else {
                Logger.orientation.debug("Preview apply skipped: orientation locked (recording).")
                return
            }
            guard let previewLayer else {
                Logger.orientation.warning("Preview apply skipped: previewLayer is nil (deallocated).")
                return
            }
            guard let connection = previewLayer.connection else {
                Logger.orientation.warning("Preview apply skipped: previewLayer.connection is nil.")
                return
            }
            connection.applyRotationAngle(angle, source: "Preview", device: device)
        }
    }

    // Custom UIView that keeps the preview layer sized correctly via layoutSubviews
    class PreviewUIView: UIView {
        fileprivate var previewLayer: AVCaptureVideoPreviewLayer?

        /// VoiceOver's equivalent of a tap-to-focus-and-expose gesture
        /// (a11y review finding — see `accessibilityCustomActions` below).
        /// Receives a DEVICE-space point, same as `CameraManager.focus(at:)`/
        /// `exposeAndMeter(at:)` expect; set by `CameraPreview.makeUIView`
        /// to route into `Coordinator.focusAndExpose(at:)`, which drives
        /// both.
        var onAccessibilityFocus: ((CGPoint) -> Void)?
        var pointActionsAllowed = true {
            didSet { updatePointActions() }
        }
        private var reticleDismissal: DispatchWorkItem?

        /// Discrete, nameable focus-and-expose targets exposed as VoiceOver
        /// custom actions, since a direct-manipulation tap gesture is
        /// unreachable once VoiceOver's own touch exploration is running —
        /// the AF/MF and AE/locked toggles alone can only flip global
        /// auto/lock, not "focus and expose *here*". DEVICE space (0...1,
        /// matching `focusPointOfInterest`'s own
        /// convention), not layer/screen space.
        private static let focusAccessibilityTargets: [(name: String, devicePoint: CGPoint)] = [
            ("Focus and expose center", CGPoint(x: 0.5, y: 0.5)),
            ("Focus and expose upper left", CGPoint(x: 0.25, y: 0.25)),
            ("Focus and expose upper right", CGPoint(x: 0.75, y: 0.25)),
            ("Focus and expose lower left", CGPoint(x: 0.25, y: 0.75)),
            ("Focus and expose lower right", CGPoint(x: 0.75, y: 0.75)),
        ]

        // Decorative tap-to-focus-and-expose feedback (Phase 4; shared with
        // Phase 5's exposure metering). Added as a real subview (not a
        // sublayer) so UIKit's normal z-ordering plus `bringSubviewToFront`
        // keep it above the preview's video sublayer regardless of setup
        // call order.
        private let focusReticleView: UIView = {
            let view = UIView(frame: CGRect(x: 0, y: 0, width: 72, height: 72))
            view.layer.borderColor = UIColor.systemYellow.cgColor
            view.layer.borderWidth = 1.5
            view.layer.cornerRadius = 8
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            view.alpha = 0
            // Decorative only — the real focus/exposure state is surfaced
            // non-visually via `FocusControlView`'s/`ExposureControlView`'s
            // accessibility values.
            view.isAccessibilityElement = false
            return view
        }()

        override init(frame: CGRect) {
            super.init(frame: frame)
            commonInit()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            commonInit()
        }

        private func commonInit() {
            addSubview(focusReticleView)

            isAccessibilityElement = true
            accessibilityLabel = "Camera preview"
            accessibilityHint = "Offers actions to focus and expose at a specific point in frame."
            // Live video, not a static image — `.updatesFrequently` is the
            // trait Apple documents for content that changes continuously.
            accessibilityTraits = .updatesFrequently
            updatePointActions()
        }

        private func updatePointActions() {
            guard pointActionsAllowed else {
                accessibilityCustomActions = []
                return
            }
            accessibilityCustomActions = Self.focusAccessibilityTargets.map { target in
                UIAccessibilityCustomAction(name: target.name) { [weak self] _ in
                    guard let self, self.pointActionsAllowed else { return false }
                    // Mirror the tap gesture's visual feedback for sighted
                    // VoiceOver users too, via the inverse of
                    // `devicePoint(for:)`.
                    self.onAccessibilityFocus?(target.devicePoint)
                    return true
                }
            }
        }

        func setupPreviewLayer(session: AVCaptureSession) {
            let layer = AVCaptureVideoPreviewLayer(session: session)
            // `.resizeAspect`, not `.resizeAspectFill`: the capture format is
            // locked to a 16:9 frame (HD or 4K, both 16:9 — see
            // `CameraManager.assignFormat`), which rarely matches a
            // device screen's aspect ratio. `.resizeAspectFill` scales the
            // frame up to fill the view and crops whatever overflows,
            // silently hiding real, recorded edges of the frame.
            // `.resizeAspect` letterboxes/pillarboxes instead (against the
            // black `backgroundColor` set in `makeUIView`), keeping the
            // on-device preview showing the full, uncropped field of view —
            // matching `ExternalDisplayController`'s HDMI mirror, which
            // already uses `.resizeAspect` for the same reason.
            layer.videoGravity = .resizeAspect
            self.layer.addSublayer(layer)
            previewLayer = layer
            bringSubviewToFront(focusReticleView)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer?.frame = bounds
        }

        /// Converts a tap's point in this view's own coordinate space into
        /// AVFoundation's device-point space (D5). The preview is
        /// `.resizeAspect`, so a naive `location.x / bounds.width`
        /// normalization would ignore the letterbox bars and focus on the
        /// wrong subject — `previewLayer` is the only thing that knows its
        /// own actual visible video rect, so the conversion must happen here.
        func devicePoint(for layerPoint: CGPoint) -> CGPoint? {
            guard let previewLayer, previewLayer.connection?.isActive == true else { return nil }
            let videoRect = previewLayer.layerRectConverted(
                fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1)
            ).intersection(previewLayer.bounds)
            guard FocusPolicy.acceptsPreviewPoint(layerPoint, videoRect: videoRect) else { return nil }
            return previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
        }

        /// Brief, transient visual feedback at a tap-to-focus point —
        /// appears, holds briefly, then fades. Purely decorative; durations
        /// collapse to near-zero under Reduce Motion rather than being
        /// skipped outright, since the reticle still needs to disappear
        /// afterward either way.
        func showFocusReticle(at layerPoint: CGPoint) {
            reticleDismissal?.cancel()
            if bounds.width > bounds.height {
                focusReticleView.layer.removeAllAnimations()
                focusReticleView.transform = .identity
                focusReticleView.center = layerPoint
                focusReticleView.alpha = 1
                let dismissal = DispatchWorkItem { [weak self] in self?.focusReticleView.alpha = 0 }
                reticleDismissal = dismissal
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: dismissal)
                return
            }
            focusReticleView.center = layerPoint
            focusReticleView.transform = CGAffineTransform(scaleX: 1.3, y: 1.3)
            focusReticleView.alpha = 0
            let reduceMotion = UIAccessibility.isReduceMotionEnabled
            UIView.animate(withDuration: reduceMotion ? 0 : 0.2, animations: {
                self.focusReticleView.alpha = 1
                self.focusReticleView.transform = .identity
            }, completion: { _ in
                UIView.animate(
                    withDuration: reduceMotion ? 0 : 0.3,
                    delay: 0.5,
                    options: [],
                    animations: { self.focusReticleView.alpha = 0 }
                )
            })
        }
    }
}
