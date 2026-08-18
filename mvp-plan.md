# Plan: CameraManager — Cine-HD Recording, Photo Library Save, Orientation Lock & HDMI Mirror

## TL;DR

Build `CameraManager` as an `@Observable` class (no `ObservableObject`) that owns a private
plain-`NSObject` `CameraSession` engine holding all AVFoundation objects, matching the mental
model in `first-file.md`:

- **UI / SwiftUI state** → normal `@Observable` properties, always mutated on main.
- **Background AVFoundation work** → `nonisolated` methods, invoked via `sessionQueue.async`.
- **Delegate callbacks → UI** → `DispatchQueue.main.async` hop inside the `nonisolated` method.

Recording format is locked to **1920x1080, 30p, H.265 (HEVC)**. Recordings save to the Photo
Library (add-only permission). Orientation is restricted to Portrait + Landscape Left only, and
is hard-locked (preview, mic source, recording, HDMI) for the duration of any recording. A second,
fixed-landscape 1080p preview mirrors the session to an HDMI display when a USB‑C/Lightning→HDMI
adapter is connected. UI is a single Record button, positioned like the native iOS Camera app.

Reference implementations used as patterns (not copied verbatim):

- `/Users/rgriola/Desktop/00-Vibecode/video-camera/video-camera/video-camera/CameraManager.swift` — the `@Observable` + private `CameraSession` engine + `sessionQueue` pattern, already working for basic record/preview.
- `/Users/rgriola/Desktop/00-Vibecode/video-camera/video-camera/video-camera/CameraPreview.swift` — `UIViewRepresentable` wrapping `AVCaptureVideoPreviewLayer`, the one sanctioned UIKit interop point.
- `/Users/rgriola/Desktop/promptcam-fixer/PromptCam/Services/CameraService.swift` — session configuration structure, format application, Photos save-on-finish pattern.
- `/Users/rgriola/Desktop/promptcam-fixer/PromptCam/Services/PermissionService.swift` — `async` permission-request style for camera/mic/photos.

---

## Steps

### Phase 1 — Recording format lock (Cine-HD 1080p30, HEVC)

_Independent — do first._

1. In `CameraSession.setupSession`, after adding `videoDevice`, `lockForConfiguration()` and
   explicitly set `activeFormat` to the device's 1920x1080 format, plus
   `activeVideoMinFrameDuration` / `activeVideoMaxFrameDuration` to `CMTime(value: 1, timescale: 30)`
   — don't rely on `session.sessionPreset` alone for the frame rate.
2. On `movieOutput`'s video connection, set `AVVideoCodecKey: AVVideoCodecType.hevc` in
   `setOutputSettings(_:for:)` before recording starts. Guard against devices whose
   `availableVideoCodecTypes` doesn't include `.hevc` by falling back to `.h264` (rare on iOS 18
   targets, but keep the guard rather than force-unwrap).
3. Add an `AVCaptureDevice.RotationCoordinator` owned by `CameraSession`, bound to the video
   device and the movie output's connection. Observe `videoRotationAngleForHorizonLevelCapture`
   via KVO and apply it to `connection.videoRotationAngle` — this is the non-deprecated
   replacement for `AVCaptureConnection.videoOrientation` and is what lets "user chooses
   orientation by turning the device" work live.

### Phase 2 — Permissions & onboarding gate

_Parallel with Phase 1._

4. Add `PHPhotoLibrary` add-only authorization (`PHAccessLevel.addOnly`) alongside camera/mic
   checks in `CameraManager`. Use `async`/`await AVCaptureDevice.requestAccess(for:)` directly
   (no completion-handler wrapping needed) — matches `PermissionService.swift`'s style and keeps
   permission checks simple since they aren't session configuration work.
5. Build `PermissionsGateView.swift`: on first launch, explains camera + microphone + photo
   library needs up front, triggers the three system prompts sequentially, and shows an
   "Open Settings" fallback button (`UIApplication.shared.open(URL(string:
UIApplication.openSettingsURLString)!)`) once any permission lands on `.denied`/`.restricted`.
6. Update `Info.plist`: add `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`,
   `NSPhotoLibraryAddUsageDescription`, and set `UISupportedInterfaceOrientations` to Portrait +
   Landscape Left only — this statically excludes Landscape Right and Portrait Upside Down at the
   OS level, no code required for the static restriction.

### Phase 3 — Save recordings to Photos

_Depends on Phase 2 step 4._

7. In `CameraSession`'s `AVCaptureFileOutputRecordingDelegate.fileOutput(_:didFinishRecordingTo:...)`,
   after the existing recording-state callback, call `PHPhotoLibrary.shared().performChanges` using
   `PHAssetCreationRequest.forAsset().addResource(...)` (add-only request type, matching the
   add-only permission scope — not `PHAssetChangeRequest`). Delete the temp file in the completion
   handler regardless of outcome. Surface errors via a new
   `onSaveError: (@Sendable (String) -> Void)?` callback, hopped to main the same way
   `onRecordingStateChange` is.

### Phase 4 — Dynamic orientation lock during recording

_Depends on Phase 1 step 3._

8. Add `AppDelegate.swift` (`NSObject, UIApplicationDelegate`) implementing
   `application(_:supportedInterfaceOrientationsFor:)`. It consults a simple shared lock flag and
   returns only the current locked orientation (`.landscapeLeft` or `.portrait`) while locked, else
   `[.portrait, .landscapeLeft]`. Wire it into `CineVideoApp.swift` via
   `@UIApplicationDelegateAdaptor`.
9. In `CameraManager.toggleRecording`, on start: freeze the Phase 1 rotation coordinator's current
   angle (stop propagating new KVO updates to preview + movie connections), set the lock flag, and
   call `windowScene.setNeedsUpdateOfSupportedInterfaceOrientations()` to force UIKit to re-query
   and lock rotation. On stop: clear the flag, resume live angle updates, and re-trigger the
   update call.
10. Guard any future audio-route-change handling with `guard !movieOutput.isRecording` so the mic
    source can't change mid-recording — satisfies "locks ... Microphone Source."

### Phase 5 — HDMI / USB→HDMI mirror output

_Parallel with Phases 2–4. Depends on Phase 1 for format._

> > > NOTE <<<
> > > Audio Follows Video for the HDMI / USB→HDMI mirror output.

11. Add `ExternalDisplayController.swift`: a plain `NSObject` (not a SwiftUI view) that observes
    `UIScene.willConnectNotification` / `didDisconnectNotification` for a scene whose
    `session.role == .windowExternalDisplay`. On connect, it creates one
    `UIWindow(windowScene:)` and hosts a second `AVCaptureVideoPreviewLayer` attached to the same
    `CameraManager.session`. This layer's `connection.videoRotationAngle` is set **once, to a
    fixed landscape value, and never updated again** — the HDMI feed is a stable 1920x1080 image
    for a TV/monitor, independent of device rotation or the recording-lock state.
    - Note: `UIWindow`/`UIScreen`/`UIScene` have no SwiftUI equivalent for external-display
      output; this is treated as isolated interop (same category as the existing
      `UIViewRepresentable` preview wrapper), not general UIKit app structure.
12. Instantiate `ExternalDisplayController` from `CineVideoApp.swift` (or `ContentView.onAppear`),
    owned for the app's lifetime, given a reference to `cameraManager.session`.

### Phase 6 — UI polish

13. Single Record button, bottom-center, styled like the native Camera app (large circular
    record/stop icon). Verify placement/sizing looks right in both allowed orientations
    (Portrait and Landscape Left), since SwiftUI layout must adapt as the user rotates.

---

## Relevant files

- `/Users/rgriola/Desktop/00-Vibecode/CineCameraApp/CineVideoApp/CineVideoApp/CameraManager.swift` — currently empty; implement `CameraSession` (format lock, HEVC, rotation coordinator, Photos save) + `CameraManager` (`@Observable`, photo auth, lock flag)
- `/Users/rgriola/Desktop/00-Vibecode/CineCameraApp/CineVideoApp/CineVideoApp/CameraPreview.swift` — new; `UIViewRepresentable` preview layer with its own `RotationCoordinator`
- `/Users/rgriola/Desktop/00-Vibecode/CineCameraApp/CineVideoApp/CineVideoApp/ContentView.swift` — replace default template; permission gate + Record button
- `/Users/rgriola/Desktop/00-Vibecode/CineCameraApp/CineVideoApp/CineVideoApp/PermissionsGateView.swift` — new
- `/Users/rgriola/Desktop/00-Vibecode/CineCameraApp/CineVideoApp/CineVideoApp/AppDelegate.swift` — new, minimal orientation-mask override
- `/Users/rgriola/Desktop/00-Vibecode/CineCameraApp/CineVideoApp/CineVideoApp/ExternalDisplayController.swift` — new, HDMI mirror
- `/Users/rgriola/Desktop/00-Vibecode/CineCameraApp/CineVideoApp/CineVideoApp/CineVideoApp.swift` — add `@UIApplicationDelegateAdaptor`, own `ExternalDisplayController`
- `/Users/rgriola/Desktop/00-Vibecode/CineCameraApp/CineVideoApp/CineVideoApp/Info.plist` — usage descriptions + `UISupportedInterfaceOrientations` (create if not present in project; currently not found under this target)

---

## Verification

1. Build via `CineVideoApp.xcodeproj` targeting a physical device — camera/mic/HDMI can't be exercised in Simulator.
2. Manual: fresh install → confirm 3 sequential permission prompts appear; denying one shows the gate's "Open Settings" button, which deep-links correctly.
3. Manual: record a clip, confirm it lands in Photos (add-only), and inspect it is HEVC, 1920x1080, 30fps (via Photos info panel or `ffprobe` on an AirDropped copy).
4. Manual: rotate device between Portrait and Landscape Left before recording — preview follows; try Landscape Right / Portrait Upside Down — app should not rotate into them.
5. Manual: start recording, then rotate device — preview, recording, and app orientation stay locked until recording stops.
6. Manual: connect a USB‑C/Lightning→HDMI adapter with a monitor attached, both before and during recording — confirm a stable, fixed-landscape 1080p mirror appears, unaffected by device rotation or the recording-lock state.

---

## Decisions

- Back camera only, no front/flip button — guide's "UI only needs Record Button" implies no camera-switch control; can add later if needed.
- Photos permission uses **add-only** scope (`PHAccessLevel.addOnly`), not full read/write — matches native Camera app behavior and is the least-privileged option that satisfies "saving to photo library."
- Rotation handled via `AVCaptureDevice.RotationCoordinator` (iOS 17+, available on iOS 18 target), not the deprecated `AVCaptureConnection.videoOrientation`.
- Recording format fixed at 1920x1080 / 30p / HEVC (H.265) — no user-facing format picker for MVP.
- `UIWindow` / `UIApplicationDelegateAdaptor` / `UIScene` are used only as minimal, isolated interop points (HDMI window, orientation mask) — no UIKit view controllers or UIKit-driven navigation anywhere in the app, consistent with the sanctioned `UIViewRepresentable`-wrapped preview layer pattern.
