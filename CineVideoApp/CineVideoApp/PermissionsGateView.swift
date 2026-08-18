//
//  PermissionsGateView.swift
//  CineVideoApp
//
//  Created by rgriola on 8/18/26.
//

import SwiftUI
import AVFoundation
import Photos

/// First-launch onboarding: explains why camera, microphone, and photo
/// library access are needed, drives the permission cascade, and falls back
/// to a Settings deep-link once anything has been denied.
struct PermissionsGateView: View {
    let cameraStatus: AVAuthorizationStatus
    let microphoneStatus: AVAuthorizationStatus
    let photoLibraryStatus: PHAuthorizationStatus
    let permissionsDenied: Bool
    let onRequestPermissions: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "camera.fill")
                .font(.system(size: 56))
                .foregroundStyle(.white)

            Text("Camera, Microphone & Photos")
                .font(.title2.bold())
                .foregroundStyle(.white)

            Text("CineVideoApp needs your camera and microphone to record video, and permission to save recordings to your Photo Library.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(alignment: .leading, spacing: 12) {
                permissionRow(title: "Camera", granted: cameraStatus == .authorized)
                permissionRow(title: "Microphone", granted: microphoneStatus == .authorized)
                permissionRow(
                    title: "Photo Library",
                    granted: photoLibraryStatus == .authorized || photoLibraryStatus == .limited
                )
            }
            .padding(.horizontal, 48)

            Spacer()

            if permissionsDenied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .padding(.bottom, 48)
            } else {
                Button("Continue") {
                    onRequestPermissions()
                }
                .buttonStyle(.borderedProminent)
                .padding(.bottom, 48)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private func permissionRow(title: String, granted: Bool) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .gray)
            Text(title)
                .foregroundStyle(.white)
            Spacer()
        }
    }
}

#Preview {
    PermissionsGateView(
        cameraStatus: .notDetermined,
        microphoneStatus: .notDetermined,
        photoLibraryStatus: .notDetermined,
        permissionsDenied: false,
        onRequestPermissions: {}
    )
}
