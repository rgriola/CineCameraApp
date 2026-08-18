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
        view.backgroundColor = .black
        view.setupPreviewLayer(session: session)
        // TEMPORARY: bumped to .error level (impossible for Console/Xcode's
        // default log-level filters to hide) purely for this diagnostic
        // pass — confirms whether makeUIView/attach ever run at all.
        Logger.orientation.error("DIAG makeUIView called. videoDevice=\(cameraManager.videoDevice != nil, privacy: .public)")
        if let device = cameraManager.videoDevice {
            context.coordinator.attach(to: view, device: device)
        }
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        // TEMPORARY: .error level — confirms whether updateUIView is even
        // being invoked again after the initial makeUIView call, and what
        // state it sees each time, without any risk of being log-filtered.
        Logger.orientation.error("DIAG updateUIView called. videoDevice=\(cameraManager.videoDevice != nil, privacy: .public) isAttached=\(context.coordinator.isAttached(to: uiView), privacy: .public)")

        // Re-attach whenever the video device becomes available for the
        // first time, OR if SwiftUI ever swaps in a new PreviewUIView/layer
        // instance underneath us (e.g. across certain relayouts triggered by
        // rotation) — otherwise the Coordinator would keep silently updating
        // a stale, now-invisible layer's connection while the visible one
        // never rotates. `isAttached(to:)` logs when this recovery kicks in.
        if let device = cameraManager.videoDevice, !context.coordinator.isAttached(to: uiView) {
            context.coordinator.attach(to: uiView, device: device)
        }
        context.coordinator.updateLockState(isRecording: cameraManager.isRecording)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(cameraManager: cameraManager)
    }

    // -------------------------------------------------------------------
    // Coordinator owns a preview-specific RotationCoordinator so the
    // on-device preview always matches how the device is held — except
    // while recording, when CameraManager.isRecording freezes it in place.
    // -------------------------------------------------------------------
    @MainActor
    final class Coordinator {
        private weak var cameraManager: CameraManager?
        private(set) var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
        private var observation: NSKeyValueObservation?
        private weak var previewLayer: AVCaptureVideoPreviewLayer?
        private weak var device: AVCaptureDevice?
        private var isLocked = false

        init(cameraManager: CameraManager) {
            self.cameraManager = cameraManager
        }

        func attach(to view: PreviewUIView, device: AVCaptureDevice) {
            guard let previewLayer = view.previewLayer else {
                Logger.orientation.error("DIAG Preview attach skipped: view has no previewLayer yet.")
                return
            }
            if self.previewLayer != nil, self.previewLayer !== previewLayer {
                Logger.orientation.error("DIAG Preview layer instance changed — reattaching RotationCoordinator.")
            }
            self.previewLayer = previewLayer
            self.device = device

            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            rotationCoordinator = coordinator
            Logger.orientation.error("DIAG Preview RotationCoordinator attached for \(device.loggingDescription, privacy: .public).")
            apply(coordinator.videoRotationAngleForHorizonLevelPreview)

            observation = coordinator.observe(
                \.videoRotationAngleForHorizonLevelPreview, options: [.new]
            ) { [weak self] _, change in
                guard let newAngle = change.newValue else { return }
                Logger.orientation.error("DIAG Preview RotationCoordinator KVO fired: raw \(newAngle, privacy: .public)°")
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
        func updateLockState(isRecording: Bool) {
            let wasLocked = isLocked
            isLocked = isRecording
            if wasLocked, !isLocked, let coordinator = rotationCoordinator {
                apply(coordinator.videoRotationAngleForHorizonLevelPreview)
            }
        }

        private func apply(_ angle: CGFloat) {
            guard !isLocked else {
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

        func setupPreviewLayer(session: AVCaptureSession) {
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            self.layer.addSublayer(layer)
            previewLayer = layer
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer?.frame = bounds
        }
    }
}
