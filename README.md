# CineVideoApp (CineCameraApp)

A SwiftUI + AVFoundation iOS camera app that records clean Cine-HD video (1920×1080, 30p, H.265/HEVC) with synchronized audio, saves recordings to the Photo Library, and mirrors a **clean** (UI-free) video + audio feed to an external monitor over a USB‑C/Lightning → HDMI adapter.

> Built as a single-purpose "cine camera" tool — no UIKit view controllers, no `ObservableObject`, minimal UI (one record button). The HDMI-out behavior intentionally mirrors dedicated HDMI-monitoring camera apps (e.g. Blackmagic Camera): the external feed is always a stable, fixed-landscape clean image, independent of how the phone is held.

## Key Features (Implemented)

- **Cine-HD recording** — video locked to 1920×1080 @ 30 fps, H.265/HEVC (falls back to H.264 only if a device genuinely can't encode HEVC), recorded with synchronized camera-mic audio via `AVCaptureMovieFileOutput`.
- **Single-button UI** — one record/stop button positioned like the native iOS Camera app; no other on-screen chrome once permissions are granted.
- **Permission onboarding gate** — sequential camera → microphone → Photo Library (add-only) permission cascade on first launch, with a status checklist and an "Open Settings" fallback button if anything is denied/restricted.
- **Save to Photo Library** — finished recordings are saved via `PHAssetCreationRequest` (add-only scope), with the temp file cleaned up afterward and save errors surfaced as an in-app alert.
- **Live rotation-following preview & recording** — an `AVCaptureDevice.RotationCoordinator` drives both the on-device preview layer and the movie output's connection as the device is turned, using the non-deprecated `videoRotationAngle` API.
- **Orientation lock during recording** — starting a recording freezes preview, recording, and the app's own supported-interface-orientations mask (via `AppDelegate` + a shared `OrientationLock`) until the recording stops, then catches both back up to the device's current angle. The app supports **Portrait + Landscape Right only** (no Landscape Left, no upside-down).
- **Clean HDMI/USB-C mirror (no app UI)** — when an external display connects, a dedicated `UIWindowSceneSessionRoleExternalDisplayNonInteractive` scene (`ExternalDisplaySceneDelegate` → `ExternalDisplayController`) presents a bare `UIWindow`/`UIViewController` hosting only an `AVSampleBufferDisplayLayer` — replacing iOS's default full-device mirror immediately on connect, before the capture session even finishes configuring. Frames are delivered through a dedicated `AVCaptureVideoDataOutput` (a second preview-layer connection isn't possible on a non-multicam session), and the HDMI connection's rotation angle is set **once, to a fixed landscape value, and never changes again** — regardless of device orientation or the recording lock.
- **Audio-follows-video on HDMI** — since `AVCaptureAudioPreviewOutput` doesn't exist on iOS, `AudioMirror` taps the session's audio via `AVCaptureAudioDataOutput` and plays it back live through `AVAudioEngine`/`AVAudioPlayerNode`, with a full graph rebuild on `AVAudioEngineConfigurationChange` (e.g. when the HDMI route changes).
- **Centralized OSLog logging** — categorized `Logger` instances (`Camera`, `Recording`, `Permissions`, `ExternalDisplay`, `Orientation`) instead of `print()`, filterable in Console.app.
- **Dependency-injected permission cascade** — `CameraManager`'s camera/mic/Photos permission sequencing runs against an injectable `PermissionsService` protocol (`SystemPermissionsService` in production), making the cascade's ordering/short-circuit logic unit-testable without real hardware or prompts.
- **Extracted pure capture policy** — codec selection, Cine-HD format selection, and recording-URL generation are pulled out into small, hardware-independent, unit-tested value types (`CapturePolicy.swift`) separate from the AVFoundation orchestration code.

## Architecture & Tech Stack

- **Swift 6.0** language mode (`SWIFT_VERSION = 6.0`), `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`. `SWIFT_STRICT_CONCURRENCY` has **not** yet been explicitly configured/reviewed (tracked as an open to-do).
- **SwiftUI only** for app UI — no `ObservableObject`; state is modeled with `@Observable`. UIKit is used only at a few deliberately isolated interop points, never for general app structure:
  - `CameraPreview` — a `UIViewRepresentable` wrapping `AVCaptureVideoPreviewLayer`.
  - `AppDelegate` (`@UIApplicationDelegateAdaptor`) — enforces the Portrait/Landscape-Right orientation mask and the recording-time lock.
  - `ExternalDisplaySceneDelegate` / `ExternalDisplayController` — a pure UIKit window + `AVSampleBufferDisplayLayer` host for the external display, since SwiftUI's `WindowGroup` cannot target an external display on iPhone.
- **AVFoundation** for all capture: `AVCaptureSession`, `AVCaptureMovieFileOutput` (recording), `AVCaptureVideoDataOutput` (feeds the HDMI mirror independently of the on-device preview layer), `AVCaptureAudioDataOutput` (feeds the HDMI audio mirror), `AVCaptureDevice.RotationCoordinator` (live rotation).
- **Photos** — `PHPhotoLibrary` add-only authorization and `PHAssetCreationRequest` for saving recordings.
- **Concurrency mental model** (per `mvp-plan.md`):
  - UI / SwiftUI state → normal `@Observable` properties on `CameraManager`, always mutated on the main actor.
  - Background AVFoundation work → `nonisolated` methods on `CameraManager`, invoked via a private serial `sessionQueue.async`. The actual AVFoundation object graph lives in a private plain `NSObject` engine (`CameraSession`, marked `@unchecked Sendable` with `nonisolated(unsafe)` fields, each owned by convention by exactly one serial queue).
  - Delegate callbacks → UI: AVFoundation delegate callbacks (recording start/finish, save errors) hop back to the main actor via `DispatchQueue.main.async` before touching `@Observable` state.
  - The video-frame sample-buffer delegate runs on its **own** dedicated serial queue (`videoDataOutputQueue`), deliberately separate from `sessionQueue`, because sharing a queue between per-frame delivery (~30/sec) and session configuration/rotation work caused frame drops in testing.
- iOS deployment target: **18.0+**. Built with Xcode 26.6 / iOS 26.5 SDK at the time of writing.

## Project Structure

```
CineCameraApp/
├── mvp-plan.md               # Original feature plan, phased implementation steps, decisions
├── camera-clean-feed.md      # HDMI clean-feed bug diagnosis + fix writeup (see "Known Limitations")
├── di-refactor.md            # Dependency-injection refactor plan for unit-testability (Phase 0 + 1 done)
├── camera-controls-plan.md   # Phased plan for camera/format controls: HD-4K, 24p/30p, zoom, focus, exposure
├── first-file.md             # Original task brief + concurrency "mental model"
└── CineVideoApp/
    ├── CineVideoApp.xcodeproj
    ├── CineVideoApp/                      # App target
    │   ├── CineVideoApp.swift             # @main App entry point, wires AppDelegate via @UIApplicationDelegateAdaptor
    │   ├── AppDelegate.swift              # Orientation mask enforcement + OrientationLock (recording-time lock)
    │   ├── ContentView.swift              # Root view: permission gate vs. camera view, record button, error alert
    │   ├── CameraManager.swift            # @Observable camera engine: session setup, format/codec lock, recording,
    │   │                                  #   permission cascade orchestration, HDMI frame-handler registration
    │   ├── CameraPreview.swift            # UIViewRepresentable on-device preview layer + its own RotationCoordinator
    │   ├── CapturePolicy.swift            # Pure, unit-tested policy: CodecSelector, CineHDFormatSelector, RecordingURL
    │   ├── PermissionsService.swift       # PermissionsService protocol + SystemPermissionsService (DI seam)
    │   ├── PermissionsGateView.swift      # First-launch permission UI with Settings deep-link fallback
    │   ├── RotationCorrection.swift       # Sensor-mount rotation correction (currently identity) + logging helpers
    │   ├── AudioMirror.swift              # AVCaptureAudioDataOutput → AVAudioEngine playback for HDMI audio
    │   ├── ExternalDisplayController.swift# Clean HDMI window/AVSampleBufferDisplayLayer presentation + wiring
    │   ├── ExternalDisplaySceneDelegate.swift # UIWindowSceneDelegate for the external-display scene role
    │   ├── Logging.swift                  # Centralized OSLog Logger categories
    │   ├── Info.plist                     # Static external-display scene manifest (merged with generated plist)
    │   └── Assets.xcassets
    └── CineVideoAppTests/                 # Unit test target (Swift Testing)
        ├── CapturePolicyTests.swift
        ├── PermissionCascadeTests.swift
        ├── PermissionGatingTests.swift
        ├── RotationCorrectionTests.swift
        └── CineVideoAppTests.swift
```

## Requirements & Permissions

- A **physical iOS device** running iOS 18.0 or later — the Simulator cannot exercise camera capture, microphone input, or external-display/HDMI output.
- An iPhone with a USB‑C (or Lightning, on older hardware) port and a USB‑C/Lightning → HDMI adapter + external monitor, if testing the HDMI mirror feature. (Verified in development with a Mokin USB hub providing power passthrough + HDMI + USB audio input simultaneously.)
- Permissions requested at first launch, in order, with system-prompt usage strings declared in the build settings:
  - **Camera** (`NSCameraUsageDescription`) — required to record video.
  - **Microphone** (`NSMicrophoneUsageDescription`) — required to record audio with the video.
  - **Photo Library — Add Only** (`NSPhotoLibraryAddUsageDescription`, `PHAccessLevel.addOnly`) — required to save finished recordings; the app never requests full read/write library access.
- If any permission is denied or restricted, the app shows an "Open Settings" button that deep-links to the app's system Settings page.

## Build & Run

1. Open `CineVideoApp/CineVideoApp.xcodeproj` in Xcode (26.6+ recommended; iOS 18.0+ deployment target).
2. Select the **`CineVideoApp`** scheme and target.
3. Select a **physical iOS device** as the run destination (not a simulator — camera, microphone, and HDMI output all require real hardware).
4. Build and run (`⌘R`). On first launch, step through the camera/microphone/Photos permission prompts.
5. To test the HDMI clean feed: connect a USB‑C/Lightning → HDMI adapter with a monitor/TV attached, either before or after launching the app. The external display should show a clean, UI-free, fixed-landscape camera image almost immediately, with camera-mic audio following automatically.

## Testing

The `CineVideoAppTests` target uses the **Swift Testing** framework (`import Testing`, `@Test`), not XCTest. All current tests are pure unit tests with no hardware/permission-prompt dependencies:

- **`CapturePolicyTests.swift`** — `CodecSelector` (HEVC-preferred, H.264 fallback), `CineHDFormatSelector` (1920×1080@30 selection logic across various synthetic format lists), and `RecordingURL` (unique `.mov` URLs in the temp directory).
- **`PermissionCascadeTests.swift`** — exercises `CameraManager`'s async permission cascade against a scripted `StubPermissionsService`: request ordering (camera → mic → photo), skipping already-granted stages, continuing the cascade after a denial (so the gate UI reflects every status), and correct final `isAuthorized`/`permissionsDenied` state across denied/restricted/limited scenarios.
- **`PermissionGatingTests.swift`** — a parameterized truth table covering `isAuthorized` (AND logic across all three permissions, `.limited` Photos counts as authorized) and `permissionsDenied` (OR logic across denied/restricted), including the "nothing determined yet" middle state and mutual-exclusivity of the two gates.
- **`RotationCorrectionTests.swift`** — a regression guard asserting `sensorMountCorrected` is a pure identity mapping (no fixed offset), per the on-device-verified decision for this camera.
- **`CineVideoAppTests.swift`** — smoke test confirming `@testable import CineVideoApp` works and a fresh `CameraManager` starts in the correct "nothing determined" permission state.

Run from Xcode (`⌘U`) with a simulator or device destination, or via CLI, e.g.:

```sh
xcodebuild test \
  -project CineVideoApp/CineVideoApp.xcodeproj \
  -scheme CineVideoApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Note: the DI refactor (`di-refactor.md`) deliberately stopped after Phase 1 (pure policy extraction + the permission-cascade seam). The rest of `CameraManager`'s AVFoundation session orchestration, `ExternalDisplayController`, and `AudioMirror` are hardware/view glue and are **not** unit-tested — they're verified on-device instead.

## Known Limitations / Current Issues

- **HDMI clean feed — resolved, with a caveat.** The app previously had a bug where the external display showed the entire app UI (the OS's default device mirror) instead of a clean camera image (see `camera-clean-feed.md`). This has been **fixed**: `ExternalDisplayController` now presents the external window immediately on scene-connect, decoupled from capture-session readiness. A residual, benign startup frame-drop transient (`FrameWasLate`, self-heals to 30fps) remains but is not a recurrence of the original bug.
- **No dynamic orientation on HDMI output.** The HDMI mirror's rotation angle is set once, to a fixed landscape value, and never updates — the team explicitly abandoned trying to make the external feed follow device rotation live, judging it too difficult to engineer at this stage (matches how Blackmagic Camera's HDMI output behaves).
- **HDMI output is always 1080p — by design, not a bug.** The external monitor feed is fixed at 1920×1080 and will **remain 1080p even once 4K recording is added** (see `camera-controls-plan.md`, decision D4). It is deliberately decoupled from the selected record format and is not user-configurable. Together with the fixed-landscape rotation above, this defines the HDMI feed as a *stable monitoring signal* independent of what the recording is doing — the same tradeoff Blackmagic Camera makes, and a deliberate protection for a frame-delivery path that already shows drop pressure (`FrameWasLate`/`OutOfBuffers`) at 1080p. Please do not "fix" this to track the record resolution.
- **Orientation support is Portrait + Landscape Right only**, locked for the duration of any recording (preview, recording, and the app's own UIKit orientation mask all freeze together, then catch back up when recording stops). Note: `mvp-plan.md`'s original plan called for Landscape **Left**, but the shipped `Info.plist`/`AppDelegate` configuration actually locks to Landscape **Right**.
- **No camera switching** — back wide-angle camera only; no front-camera flip, no lens/zoom picker. Note the active device is `.builtInWideAngleCamera`, a *single-lens* device on which zoom across focal lengths is impossible; adding zoom requires moving to a virtual multi-lens device (`camera-controls-plan.md`, decision D2).
- **No manual capture controls** — no exposure/shutter/ISO adjustment or lock, no STANDARD/CINE mode toggle, no HD/UHD or 24p/30p toggle. Recording format is hard-locked to 1920×1080 @ 30p H.265. A phased plan to add format, frame-rate, zoom, focus, and exposure controls is written up in `camera-controls-plan.md` (ISO/shutter deferred to a later phase); not yet implemented.
- **No external/USB microphone selection UI** — the app always plays back/records through the system's current default audio route; it cannot detect or let the user pick a specific external mic (e.g. DJI Mic, Rode). Explicitly called out as a to-do.
- **`SWIFT_STRICT_CONCURRENCY` has not been reviewed/configured** — an open item from `mvp-plan.md`.
- **Default/placeholder app icon** — a real app icon has not been added yet.
- **iOS 27 external-display "scene accessory" path is dormant.** `ExternalDisplaySceneDelegate.swift` contains a fully written `registerSceneAccessory` implementation for the upcoming iOS 27 external-display API, wrapped in `#if false` because those symbols don't exist in the iOS 26.5 SDK this project currently builds against. The static `Info.plist` scene-manifest mechanism (used today) will stop auto-connecting the external-display scene on iOS 27+, so this block must be enabled once building against that SDK.
- **DI refactor stopped at Phase 1.** Per `di-refactor.md`, Phase 2 (a `PhotoLibrarySaving` seam for the Photos-save path) and Phase 3 (a `CaptureSessionControlling` lifecycle abstraction) are explicitly deferred/out of scope; the Photos-save and session-lifecycle code paths remain untested by unit tests.
- **USB-C hub behavior with simultaneous external display + USB microphone input** is called out as an open need in `mvp-plan.md`, not confirmed/implemented.

## Roadmap / To-Do

Pulled from the "To-Do" / "Needs" sections of `mvp-plan.md`, `camera-clean-feed.md`, and `di-refactor.md`:

- [ ] Add external/USB microphone input support and selection UI (review PromptCam's audio model for best practice).
- [ ] Review and explicitly configure `SWIFT_STRICT_CONCURRENCY`.
- [ ] Add a real app icon.
- [ ] Confirm USB-C hub behavior for simultaneous external display + USB microphone input.
- [ ] Camera controls: HD/4K format toggle, 24p/30p frame rate, zoom, focus/AF toggle, exposure/AE + EV bias — phased plan in `camera-controls-plan.md` (Phase 0 = pure testable policy, no behavior change).
- [ ] Camera controls, later phase: manual ISO + shutter speed (`setExposureModeCustom`), plus a STANDARD/CINE mode toggle.
- [ ] Move the capture device from `.builtInWideAngleCamera` to a virtual multi-lens device (triple → dual-wide → dual → wide fallback chain) as a prerequisite for zoom — note this requires pinning the initial zoom factor to the 1× anchor so framing doesn't silently regress to 0.5× ultra-wide.
- [ ] Additional record formats beyond the current 1080p30 lock: UHD 3840×2160 @24/30p, HD 1920×1080 @24p, plus Cine variants. **HDMI output stays fixed at 1080p regardless** — see "Known Limitations".
- [ ] Enable the dormant iOS 27 `registerSceneAccessory` external-display path once building against the iOS 27 SDK, and verify its API shapes against Apple's current documentation.
- [ ] DI refactor Phase 2 — a `PhotoLibrarySaving` seam for unit-testing the Photos-save path.
- [ ] DI refactor Phase 3 — a narrow `CaptureSessionControlling` lifecycle abstraction (or a deliberate decision to skip it).
- [ ] Gate the per-150-frame debug/warning frame logs behind `#if DEBUG` so Release builds carry zero per-frame logging overhead (currently left in deliberately for diagnostics).
