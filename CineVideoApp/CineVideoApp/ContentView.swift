//
//  ContentView.swift
//  CineVideoApp
//
//  Created by rgriola on 8/18/26.
//

import SwiftUI

struct ContentView: View {
    @State private var cameraManager = CameraManager.shared

    var body: some View {
        Group {
            if cameraManager.isAuthorized {
                cameraView
            } else {
                // phone resource permissions.
                PermissionsGateView(
                    cameraStatus: cameraManager.cameraAuthStatus,
                    microphoneStatus: cameraManager.microphoneAuthStatus,
                    photoLibraryStatus: cameraManager.photoLibraryAuthStatus,
                    permissionsDenied: cameraManager.permissionsDenied,
                    onRequestPermissions: { cameraManager.checkPermissions() }
                )
            }
        }
        .onAppear {
            cameraManager.checkPermissions()
        }
        .alert(
            "Recording Error",
            isPresented: Binding(
                get: { cameraManager.lastError != nil },
                set: { isPresented in if !isPresented { cameraManager.lastError = nil } }
            )
        ) {
            Button("OK") { cameraManager.lastError = nil }
        } message: {
            Text(cameraManager.lastError ?? "")
        }
    }

    // Phase 6: preview + Format/Zoom/Focus/Exposure control chrome + record
    // cluster, composed in `CameraScreen` (see camera-controls-plan.md).
    private var cameraView: some View {
        CameraScreen(cameraManager: cameraManager)
    }
}

#Preview {
    ContentView()
}
