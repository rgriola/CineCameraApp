# Clean HDMI Feed (Video + Audio) — Diagnosis & Fix Plan

**App:** CineVideoApp (SwiftUI + AVFoundation, iOS 18 deployment target, built with Xcode 26 / iOS 26.5 SDK)
**Goal:** Feed a *clean* camera image (no app UI) plus camera-mic audio out of an iPhone over a USB‑C/Lightning → HDMI adapter, the way Blackmagic Camera does for video — but with audio too.
**Status:** Resolved. On-device, untethered: clean camera-only image on HDMI, live camera-mic audio, HDMI window appears immediately on launch/relaunch. A brief startup lag self-heals to a locked 30 fps.

---

## 1. The wall we hit

The HDMI output showed the **entire app UI** (record button, status bar, etc.) instead of just the camera preview. Two theories were on the table:

1. The `UIWindowScene` / external-display scene mechanism was "blocked" by iOS or the app.
2. A second SwiftUI `WindowGroup` in the app's `@main` entry point could drive the external monitor.

Both theories turned out to be wrong, but they pointed us at the right subsystem.

## 2. What the codebase already had right

The implementation had already avoided the three classic dead-ends (each confirmed on-device previously):

- **Not** a second `AVCaptureVideoPreviewLayer` — a non-multicam `AVCaptureSession` rejects a second preview-layer connection on the same input port (`canAddConnection == false`). Instead the HDMI feed is driven by a distinct `AVCaptureVideoDataOutput` → `AVSampleBufferDisplayLayer`.
- **Not** the deprecated `UIScreen.didConnectNotification` + `UIWindow(screen:)` path — deprecated in iOS 16; on modern iOS a scene-less window is inert for real display output and just yields the system mirror.
- A correct `AVSampleBufferDisplayLayer` **control timebase** synced to the host clock (otherwise every incoming frame looks scheduled far in the future and the render queue backs up forever).
- Audio-follows-video via `AVCaptureAudioDataOutput` → `AVAudioEngine`/`AVAudioPlayerNode` (since `AVCaptureAudioPreviewOutput` is unavailable on iOS), with a full engine rebuild on `AVAudioEngineConfigurationChange` (route changes when HDMI connects).

So the capture/render/audio pipeline was sound. The problem was elsewhere.

## 3. Root-cause diagnosis

### 3a. Platform reality (researched against current Apple docs)

- iPhone **does** support presenting *separate, non-mirrored* content to an external display — but only through the **`windowExternalDisplayNonInteractive`** scene role (non-interactive = no touch on the external screen, which is fine for a monitor feed). This is the same mechanism Blackmagic uses for its clean feed.
- **Mirroring is the default fallback.** iOS keeps showing its full-screen *device mirror* (the whole app UI) on the external display until the app **presents its own `UIWindow` on that external `UIWindowScene` and calls `makeKeyAndVisible()`**. No app window on the scene → mirror stays up. That is exactly the "HDMI shows the entire app UI" symptom.
- **SwiftUI `WindowGroup` cannot target an external display on iPhone** (multi-window only extends on macOS/iPadOS). Theory #2 is a dead end; the UIKit scene-delegate route is the only supported path. (SwiftUI content can still be surfaced inside the external window via `UIHostingController` if overlays are ever wanted.)
- **iOS 27+ behavioral change:** the static `UISceneConfigurations` manifest no longer auto-connects the external-display scene; the app must call `registerSceneAccessory(_:)` from a live view controller and keep the returned registration alive. On iOS ≤ 26 the Info.plist manifest still auto-connects, so both mechanisms must coexist.

### 3b. The actual bug in our code

`ExternalDisplayController` gated **window creation** behind camera-session readiness:

```
attachWhenReady(to:) → if CameraManager.shared.videoDevice == nil { retry later; return }
                     → only then create the UIWindow + makeKeyAndVisible()
```

Because the external-display scene can connect within milliseconds of launch — well before the async permission cascade and session configuration finish — the window was often not created for a while (or not at all if configuration stalled). During that gap **iOS kept the full-UI mirror up**. Window lifecycle was incorrectly coupled to capture readiness.

## 4. The fixes applied

### Fix 1 — Present the external window immediately; decouple it from capture readiness

`ExternalDisplayController.swift`

- Renamed `attachWhenReady(to:)` → `attach(to:)`. It now creates the `UIWindow(windowScene:)`, installs a bare `UIViewController` hosting only the `AVSampleBufferDisplayLayer` (no app chrome), and calls `makeKeyAndVisible()` **unconditionally on scene-connect**, with a black background. This stops the OS mirror instantly.
- Added `wireCaptureWhenReady()`: only the **video-frame subscription + audio mirroring** wait for `videoDevice` (retrying every 500 ms). It fills the already-visible black window with the live feed once the session is ready. It is teardown-safe (bails if the window/layer was removed).
- Added a re-entrancy guard (`if externalWindow != nil { teardown() }`) for scene reconnects.
- `ExternalDisplaySceneDelegate.swift` updated to call the renamed `attach(to:)`.

Result: mirror is replaced by the app's clean window the moment the scene connects, regardless of camera timing.

### Fix 2 — iOS 27+ scene-accessory registration (dormant, ready to enable)

`ExternalDisplaySceneDelegate.swift`

- Added a fully documented `registerSceneAccessory(_:)` implementation (an `ExternalDisplayAccessoryView` / `ExternalDisplayAccessoryController`) guarded by `#if false`.
- It is intentionally inert because the iOS 27 symbols (`registerSceneAccessory`, `UISceneAccessory`, `UISceneAccessoryRegistration`) **do not exist in the iOS 26.5 SDK** this project builds against — referencing them would break the build even behind an `#available` check (that guards runtime, not SDK, availability).
- To enable when building against the iOS 27+ SDK: flip `#if false` → `#if true`, verify the API shapes against Apple's "Presenting content on a connected display," and add `.background(ExternalDisplayAccessoryView())` to `ContentView`. Keep the Info.plist manifest for iOS ≤ 26.

### Fix 3 — Drop-reason diagnostics

`CameraManager.swift` (`AVCaptureVideoDataOutputSampleBufferDelegate.captureOutput(_:didDrop:from:)`)

- Added `dropReason(for:)`, which reads the `kCMSampleBufferAttachmentKey_DroppedFrameReason` attachment and logs it (throttled, every 150th drop) as `reason=FrameWasLate | OutOfBuffers | Discontinuity`. This distinguishes a benign startup/thermal congestion transient (`FrameWasLate`, expected with `alwaysDiscardsLateVideoFrames = true`) from a real buffer-retention bug (`OutOfBuffers`).

## 5. On the frame drops

The first on-device log showed ~92% frame drops for ~60 s, then a **hard lock to a clean 30.0 fps with zero drops** for 5+ minutes. Analysis of the throttled log timestamps (150 frames per 5.000 s once settled) confirmed this is a **startup congestion transient**, not a steady-state defect — and drops occurred even before any HDMI handler was attached, so they were not caused by app-side per-frame work. Primary contributors: running under the Xcode debugger with live Console log streaming plus the normal launch storm (session config, 1080p30/HEVC setup, rotation KVO, audio-engine spin-up, permission checks).

Untethered testing confirmed the expected improvement: HDMI window appears immediately, only a slight startup lag that self-heals. `alwaysDiscardsLateVideoFrames = true` is correct here — a low-latency monitor should shed late frames rather than accumulate latency.

## 6. Startup transient — analysis & optional future tuning

### What it is (confirmed on device)

- Every startup drop logs `reason=FrameWasLate` — **never `OutOfBuffers`**. This is the *benign* reason: with `alwaysDiscardsLateVideoFrames = true`, a frame that arrives while the delegate queue is still busy is discarded rather than queued. So the transient shows up as briefly reduced fps, **not** accumulating latency, and it is **not** a buffer-retention/leak bug (which would log `OutOfBuffers`).
- Drops occur even before the HDMI handler attaches (`handlerAttached=false`), so they are **not** caused by app-side per-frame work — the bottleneck is system-level resource contention during launch.
- The feed reliably self-heals to a **measured 30.00 fps** (150 frames per 5.000 s) with zero drops, and holds there indefinitely.
- Observed transient length varied roughly 30–90 s across runs, correlating with how much observation overhead was active (Xcode debugger and/or live `log stream`/Console.app).

### Contributing factors (in rough order of impact)

1. **Observation overhead** — running under the Xcode debugger and/or streaming os_log to Console with debug level enabled taxes the media threads heavily during launch. A fully untethered relaunch (tap the app icon, no log streaming) showed the HDMI window appearing essentially immediately with a much shorter transient. **Tethered/streamed numbers are a worst case, not representative of a shipped app.**
2. **Launch storm** — session configuration, the switch to the 1080p30 active format, HEVC setup, `RotationCoordinator` KVO, `AVAudioEngine` spin-up, and the permission/Photos checks all land in the first second or two and oversubscribe the CPU while the pipeline is warming up.
3. **AVFoundation startup chatter** — `FigCaptureSourceRemote err=-17281` / `FigAudioSession err=-19224` are normal XPC handshake races at launch; noisy but not fatal and not the drop cause.

### Optional future tuning (only if the transient needs to be shorter — NOT required)

The feature is ship-ready as-is; these are levers to shorten the warm-up, not fixes for a defect:

- **Measure untethered first.** Before tuning anything, confirm the real (icon-launch, no log streaming) transient length — it is materially shorter than the tethered logs suggest. Don't optimize against the debugger's overhead.
- **Defer non-essential startup work.** Attach the audio-mirror tap and the rotation-coordinator KVO a beat *after* the first HDMI frames are flowing, so the initial pipeline warm-up isn't competing with them.
- **Gate the per-150-frame `.debug`/`.warning` frame logs behind `#if DEBUG`** so the shipping (Release) build carries zero per-frame logging overhead. (Deliberately left in for now at the owner's request.)
- **Consider a lower-cost HDMI tap during warm-up** if ever needed — e.g. `AVCaptureVideoDataOutput.deliversPreviewSizedOutputBuffers` or a reduced tap resolution — trading external-display sharpness for fewer late frames. Not currently warranted, since it settles clean at full 1080p30.
- **Keep `alwaysDiscardsLateVideoFrames = true`.** For a live monitor, shedding late frames (brief fps dip) is preferable to queuing them (growing latency). Do not switch this to `false` to "save" the dropped frames.

## 7. Design decisions locked in (do not revisit)

- **Keep** `AVCaptureVideoDataOutput` + `AVSampleBufferDisplayLayer` for HDMI. A second `AVCaptureVideoPreviewLayer` is not an option on a non-multicam session (confirmed `canAddConnection == false`).
- **Keep** the external window as a pure-UIKit host (bare `UIViewController` + layer), not SwiftUI — the reliable path for a non-key external `UIWindow`. (PromptCam reached the same conclusion, moving from a SwiftUI `CleanPreviewView`/`UIHostingController` to a pure UIKit host.)
- **Keep** the Info.plist static scene manifest for iOS ≤ 26; add `registerSceneAccessory` for iOS 27+.
- **Do not** add a second SwiftUI `WindowGroup` for the external display — unsupported on iPhone.
- **Keep** `alwaysDiscardsLateVideoFrames = true` for the HDMI tap.

## 8. Files changed

- `CineVideoApp/CineVideoApp/ExternalDisplayController.swift` — window presented immediately on scene-connect; `wireCaptureWhenReady()` decoupled from window lifecycle; re-entrancy guard.
- `CineVideoApp/CineVideoApp/ExternalDisplaySceneDelegate.swift` — call `attach(to:)`; dormant iOS 27 `registerSceneAccessory` block.
- `CineVideoApp/CineVideoApp/CameraManager.swift` — drop-reason logging.

## 9. Verification checklist

- [x] Clean camera-only image on HDMI (no app UI / mirror).
- [x] Live camera-mic audio out the HDMI route.
- [x] HDMI window appears immediately on launch and relaunch (untethered).
- [x] Feed self-heals to a stable 30 fps after a brief startup lag.
- [x] Confirmed drop `reason=FrameWasLate` on device (benign, expected with `alwaysDiscardsLateVideoFrames = true`) — **no `OutOfBuffers`** observed, ruling out buffer-retention/leak bugs. After the startup transient the feed locks to a measured 30.00 fps (150 frames per 5.000 s) with zero drops and holds steady.
- [ ] Future: enable and test the iOS 27 `registerSceneAccessory` path once on the iOS 27 SDK / an iOS 27 device.

## 10. Console log reference (what "healthy" looks like)

- `External-display scene connecting.` — scene connected.
- `HDMI mirror window presented; device mirroring stopped.` — app window took over; mirror gone (should be near-immediate).
- `HDMI window shown; awaiting capture session before wiring frames.` → `HDMI live feed wired: video frames + audio mirroring active.` — live feed attached once session ready.
- `HDMI renderer enqueue #N` at a steady 150-per-5.000 s cadence — locked 30 fps.
- `Audio mirror engine started: 48000.0Hz, 1ch.` — audio path live.
