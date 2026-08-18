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
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        // Re-applies on every render in case the connection resets (e.g.
        // after the session reconfigures); cheap no-op once already set.
        context.coordinator.attach(to: uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(cameraManager: cameraManager)
    }

    // -------------------------------------------------------------------
    // TEMPORARY (branch fix/horizontal-preview): hardcodes the preview to
    // Landscape Right instead of tracking live device rotation — see
    // RotationCorrection.swift for why.
    // -------------------------------------------------------------------
    @MainActor
    final class Coordinator {
        private weak var cameraManager: CameraManager?

        init(cameraManager: CameraManager) {
            self.cameraManager = cameraManager
        }

        func attach(to view: PreviewUIView) {
            guard let connection = view.previewLayer?.connection else { return }
            connection.applyHardcodedLandscapeRight(source: "Preview", device: cameraManager?.videoDevice)
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
