//
//  CameraPreview.swift
//  CineVideoApp
//
//  Created by rgriola on 8/18/26.
//

import SwiftUI
import AVFoundation

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let cameraManager: CameraManager

    func makeUIView(context: Context) -> PreviewUIView {
        let view: CameraPreview.PreviewUIView = PreviewUIView()
        view.backgroundColor = .black
        view.setupPreviewLayer(session: session)
        if let device = cameraManager.videoDevice {
            context.coordinator.attach(to: view, device: device)
        }
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        // The video device isn't known until the session finishes configuring
        // (after the permission cascade completes), so attach lazily here.
        if context.coordinator.rotationCoordinator == nil, let device = cameraManager.videoDevice {
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
        private var isLocked = false

        init(cameraManager: CameraManager) {
            self.cameraManager = cameraManager
        }

        func attach(to view: PreviewUIView, device: AVCaptureDevice) {
            guard let previewLayer = view.previewLayer else { return }
            self.previewLayer = previewLayer

            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            rotationCoordinator = coordinator
            apply(coordinator.videoRotationAngleForHorizonLevelPreview)

            observation = coordinator.observe(
                \.videoRotationAngleForHorizonLevelPreview, options: [.new]
            ) { [weak self] _, change in
                guard let newAngle = change.newValue else { return }
                Task { @MainActor [weak self] in
                    self?.apply(newAngle)
                }
            }
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
            guard !isLocked,
                  let previewLayer,
                  let connection = previewLayer.connection
            else { return }
            let corrected = angle.landscapeCorrected
            guard connection.isVideoRotationAngleSupported(corrected) else { return }
            connection.videoRotationAngle = corrected
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
