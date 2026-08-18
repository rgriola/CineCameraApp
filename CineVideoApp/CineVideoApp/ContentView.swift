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

    private var cameraView: some View {
        ZStack(alignment: .bottom) {
            CameraPreview(
                session: cameraManager.session, 
                cameraManager: cameraManager
                )
                .ignoresSafeArea()

            Button {
                cameraManager.toggleRecording()
            } label: {
                Image(systemName: cameraManager.isRecording ? "stop.circle.fill" : "record.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(cameraManager.isRecording ? .red : .white)
            }
            .disabled(!cameraManager.isSessionRunning)
            .padding(.bottom, 32)
        }
    }
}

#Preview {
    ContentView()
}
