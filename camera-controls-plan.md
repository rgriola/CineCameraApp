# CineCameraApp — Camera & Format Controls Extension Plan

**Target:** iOS 18.0+ · Swift 6 · SwiftUI (no UIKit chrome) · AVFoundation
**Scope of this plan:** Record Format (4K/HD), Frame Rate (24p/30p), Zoom, Focus/AF, Exposure/AE, External Audio Sources + VU metering
**Deferred to a later phase:** ISO, Shutter Speed

---

## 0. Baseline — what exists today

| Concern                | Current state                                                                                                                            | File                              |
| ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------- |
| State container        | `@Observable final class CameraManager: NSObject`, singleton `.shared`                                                                   | `CameraManager.swift:229`         |
| AVFoundation ownership | `private final class CameraSession: NSObject, @unchecked Sendable`, all fields `nonisolated(unsafe)`, owned by `sessionQueue`            | `CameraManager.swift:19`          |
| Threading              | Serial `sessionQueue`; separate `videoDataOutputQueue` for sample buffers; `DispatchQueue.main.async` hops to mutate `@Observable` state | `CameraManager.swift`             |
| Device                 | `AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)` — **single lens, no zoom possible**                     | `CameraManager.swift:478`         |
| Format                 | Hardcoded 1920×1080@30 via `applyCineHDFormat`                                                                                           | `CameraManager.swift:557`         |
| Format policy          | Pure, unit-tested `CineHDFormatSelector` / `CaptureFormatDescriptor` / `CodecSelector`                                                   | `CapturePolicy.swift`             |
| Preview                | `CameraPreview: UIViewRepresentable` + `PreviewUIView` + per-preview `RotationCoordinator`                                               | `CameraPreview.swift`             |
| Preview gravity        | `.resizeAspect` (letterboxed, uncropped — fixed this session)                                                                            | `CameraPreview.swift:133`         |
| HDMI out               | `videoDataOutput` → `ExternalDisplayController` → `AVSampleBufferDisplayLayer` (`.resizeAspect`), locked to landscape 0°                 | `ExternalDisplayController.swift` |
| UI                     | `ZStack(alignment: .bottom)` with preview + a single record button                                                                       | `ContentView.swift:46`            |
| Audio input            | `AVCaptureDevice.default(for: .audio)` — **no source selection, no metering**                                                            | `CameraManager.swift:485`         |
| Audio session          | `.playAndRecord`, mode `.videoRecording`, options `[.allowBluetoothA2DP, .defaultToSpeaker]` — **A2DP is output-only; no BT mic input**   | `CameraManager.swift:610`         |
| HDMI audio             | `AudioMirror` taps the session's **one** `AVCaptureAudioDataOutput` → `AVAudioEngine`/`AVAudioPlayerNode`; added **only on HDMI connect** | `AudioMirror.swift`               |
| Tests                  | Swift Testing (`import Testing`, `@Test`, `#expect`)                                                                                     | `CapturePolicyTests.swift`        |
| Logging                | `Logger.camera` / `.recording` / `.permissions` / `.externalDisplay` / `.orientation`                                                    | `Logging.swift`                   |

### What PromptCam actually gives us

Researched `/promptcam-fixer`. Reusable patterns:

- `RecordingFormat` value model — `Codable`/`Sendable` struct of independent enums, `.default`, `loadSaved()`/`save()` (`Models/RecordingFormat.swift`)
- `applyFormat` guard pattern — reject format changes while `movieFileOutput.isRecording` (`Services/CameraService+Format.swift:14-25`)
- Frame-rate fallback — probe `activeFormat.videoSupportedFrameRateRanges`, degrade to highest supported (`CameraService+Format.swift:491-518`)
- Combined focus+exposure point/lock semantics, `.locked` ⇄ `.continuousAuto*` (`Services/CameraService+Controls.swift:37-190`)
- EV bias clamped to `device.min/maxExposureTargetBias` (`CameraService+Controls.swift:158-196`)
- `StandardPanel` overlay container + `Theme` tokens; controls `.disabled(isRecording).opacity(isRecording ? 0.3 : 1.0)`

**Critical gap:** _PromptCam implements no zoom at all._ No `videoZoomFactor`, no pinch gesture, no lens switching — it is a selfie-cam app on a single front lens. **The entire zoom feature must be designed from scratch here.** Do not go looking for a PromptCam reference implementation.

Also note PromptCam uses `sessionPreset` for its Standard mode — **we deliberately diverge** (see Decision D1).

**Audio — PromptCam has a strong, production-hardened implementation** (`Services/AudioMeterService.swift`, `ViewModels/AudioMeterViewModel.swift`, `Views/Camera/VUMeterView.swift`, `Views/Camera/AudioSourcePickerView.swift`). Directly reusable:

- Source list from `AVAudioSession.availableInputs`, selection applied via `setPreferredInput(_:)`; `nil` restores the system default (`AudioMeterService.swift:999-1018`)
- Port-type → icon/label mapping for `.builtInMic` / `.headsetMic` / `.usbAudio` / `.bluetoothHFP` / `.bluetoothA2DP` (`AudioSourcePickerView.swift:92-128`)
- `AVCaptureDevice.DiscoverySession` used **only** to resolve a nicer product name, mapped by `uniqueID` → `localizedName` (`AudioSourcePickerView.swift:17-26`)
- **1 Hz polling instead of `routeChangeNotification`** — a hard-won production finding: USB interfaces that enumerate as port type `"Other"` do **not** reliably fire route-change notifications (`AudioMeterService.swift:633-674`). `interruptionNotification` is still observed separately for calls/Siri.
- Preferred-UID memory so an unplugged device is automatically reclaimed when it returns (`AudioMeterService.swift:697-706`)
- RMS via `vDSP_rmsqv` → `20·log10` → normalize `(dB + 60)/60`, floor −60 dBFS (`AudioMeterService.swift:501-527`)
- Peak ballistics: jump up instantly, hold 1.5 s, then decay 15% of the remaining delta per buffer (`AudioMeterService.swift:568-575`)
- UI publish rate-limited to 30 fps (`AudioMeterService.swift:27`); meter animates `.linear(duration: 0.05)`
- Stereo detected from `format.channelCount >= 2`, channels metered independently (`AudioMeterService.swift:330-337`)
- Silence watchdog on **peak** (not RMS) — floor `0.0001`, 5 s threshold — so quiet room tone isn't misreported as a dead mic (`AudioMeterService.swift:31-42`)
- Mid-recording route changes surface a warning banner instead of reconfiguring (`AudioMeterViewModel.swift:115-143`)

**Where we diverge:** PromptCam meters through a *separate* `AVAudioEngine` input-node tap. CineCameraApp must **not** copy that — see Decision D11.

---

## 1. Key design decisions (read before coding)

**D1 — Keep `activeFormat` selection; never set `sessionPreset`.**
CineCameraApp needs deterministic cine formats, and already has a tested pure selector. Setting `device.activeFormat` implicitly moves the session to `.inputPriority`. Do **not** assign `session.sessionPreset` anywhere afterward — it would silently override the chosen format.

**D2 — Upgrade the capture device to a virtual multi-lens device.** Zoom across "a wide range of focal lengths" is impossible on `.builtInWideAngleCamera`. Use an `AVCaptureDevice.DiscoverySession` fallback chain:
`.builtInTripleCamera` → `.builtInDualWideCamera` → `.builtInDualCamera` → `.builtInWideAngleCamera`.

**D2a — ⚠️ Framing regression hazard.** On a virtual device, `videoZoomFactor == 1.0` is the **ultra-wide** lens (UI "0.5×"), _not_ 1×. If we switch device without compensating, the app silently starts at 0.5× — a visible regression. On first configure, set the initial zoom to the 1× equivalent:

```swift
device.videoZoomFactor = 1.0 / device.displayVideoZoomFactorMultiplier
```

**D3 — Use `displayVideoZoomFactorMultiplier` (iOS 18+) for zoom labels.** Verified available on our deployment target. `displayedZoom = videoZoomFactor * device.displayVideoZoomFactorMultiplier`, and inversely `videoZoomFactor = displayedZoom / multiplier`. This replaces the old hardcoded per-device mapping tables. Derive lens-preset buttons from `virtualDeviceSwitchOverVideoZoomFactors` (converted through the same multiplier) so presets are correct on every device instead of hardcoded 0.5/1/2/3.

**D4 — 🔒 PROJECT INVARIANT: HDMI output is ALWAYS 1080p.**
The external monitor feed is fixed at 1920×1080 regardless of the selected recording format. It is **not** user-configurable and must never track the record resolution. This sits alongside the existing HDMI invariant that the feed is always fixed-landscape (`lockHDMIToLandscape`) — together they define the external feed as a _stable monitoring signal_, decoupled from whatever the recording is doing. This mirrors Blackmagic Camera's behavior and protects a path that already logs `FrameWasLate`/`OutOfBuffers` pressure at 1080p.

Implement by pinning `videoDataOutput.videoSettings` (iOS 16+, aspect-matched 16:9→16:9):

```swift
videoDataOutput.videoSettings = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: 1920,
    kCVPixelBufferHeightKey as String: 1080,
]
```

Recording still captures at full 4K when selected. **Must be re-applied after every format change** (see D9) — an `activeFormat` change resets the output's negotiated dimensions.

**Documentation requirement:** this invariant must be stated explicitly in `README.md` (Key Features + Known Limitations) so it is never mistaken for a bug or "fixed" by a later contributor.

**D5 — Tap-to-focus MUST use `previewLayer.captureDevicePointConverted(fromLayerPoint:)`.**
Because the preview is now `.resizeAspect` (letterboxed), a naive `location.x / size.width` normalization is **wrong** — it ignores the black bars and would focus on the wrong subject, worse the further from center. The conversion must happen inside `PreviewUIView`, which owns the layer. Expose it as a method on `CameraPreview.PreviewUIView` and surface a `UITapGestureRecognizer` (or a SwiftUI `.onTapGesture` whose point is forwarded into the view for conversion).

**D6 — Control availability during recording.**

- Format + frame rate: **hard-blocked** while `movieOutput.isRecording` (matches the existing `setupSession` guard and PromptCam). Grey out in UI _and_ reject in the service.
- Zoom / focus / exposure: **allowed live** — this is a cine app; operators pull focus and zoom mid-take.
- Orientation remains locked during recording (existing behavior, untouched).

**D7 — Place chrome in the letterbox bars.** With `.resizeAspect` + a 16:9 frame on a ~19.5:9 screen there are substantial black bars. Put controls there so they never cover image. Do **not** reintroduce cropping or shrink the preview to make room.

**D8 — Concurrency: follow the existing pattern exactly.** Every device mutation is a `nonisolated` method dispatched on `sessionQueue`, wrapped in `lockForConfiguration()` / `defer { unlockForConfiguration() }`, pushing results back via `DispatchQueue.main.async`. Do **not** introduce actors, `ObservableObject`, or a new queue. Per project rules: `@Observable` only.

**D9 — Format change invalidates dependent state.** After any `activeFormat` assignment you must, in order: re-apply frame rate → re-clamp and re-apply zoom (`videoMaxZoomFactor` changes per format) → re-apply `videoDataOutput.videoSettings` (D4) → re-verify the HEVC codec on the movie connection. Encode this as one ordered private method so it can't be done piecemeal.

**D10 — ⚠️ You cannot pick a microphone with `AVCaptureDevice`. Audio input selection is an `AVAudioSession` concern.**
Verified against both Apple's documented behavior and PromptCam's production code. On iOS, `AVCaptureDevice.default(for: .audio)` returns a single **proxy** device whose `uniqueID` stays `built-in_audio:0` regardless of what's plugged in; only its `localizedName` follows the active route. `AVCaptureDevice.DiscoverySession` for `.audio` does **not** enumerate USB/Bluetooth mics as separate selectable devices (that's macOS behavior).

The only working mechanism is:
```swift
let session = AVAudioSession.sharedInstance()
let inputs = session.availableInputs ?? []        // the real, selectable list
try session.setPreferredInput(chosenPort)          // nil == system default
```
…and the `AVCaptureSession` then captures from whatever route `AVAudioSession` selected. Because the proxy device's identity never changes, the capture input only needs re-creating so the session re-resolves the route — see D12 for when that's allowed. Use `AVCaptureDevice.DiscoverySession` **only** to look up a friendlier product name for display.

**D11 — Meter from the existing `AVCaptureAudioDataOutput`, NOT a second `AVAudioEngine` (diverges from PromptCam).**
Two hard constraints force this:
1. **An `AVCaptureSession` permits only ONE `AVCaptureAudioDataOutput`** — `canAddOutput` returns `false` for a second. `AudioMirror` already occupies that single slot.
2. Adding a second `AVAudioEngine` input tap alongside `AudioMirror`'s existing playback engine invites input-node contention and another `AVAudioEngineConfigurationChange` rebuild path, on a graph whose stale-configuration crashes are already documented in `AudioMirror.swift`.

Instead, compute RMS **inside the sample-buffer delegate `AudioMirror` already has**. The buffers are arriving anyway; metering them is nearly free and requires no new output, no new engine, and no new queue.

This is also *more correct* for a cine app: it meters exactly the audio being recorded, rather than a parallel engine's view of the input.

**Required refactor:** `AudioMirror`'s audio tap is currently added to the session **only when HDMI connects** (`ExternalDisplayController.enableAudioMirroring()`). Metering must work with no monitor attached, so the output becomes **permanently installed at session setup**, and *playback* becomes the part that toggles on HDMI connect/disconnect. Rename the type to reflect its widened role (e.g. `AudioTap`, owning both metering and optional mirror playback). Keep `AVCaptureAudioChannel.averagePowerLevel` in mind as a rejected alternative — it gives no control over ballistics and is unreliable outside an active recording.

**D12 — Mic source is LOCKED during recording (existing project invariant).**
`mvp-plan.md` already specifies: *"Guard any future audio-route-change handling with `guard !movieOutput.isRecording` so the mic source stays locked during recording."* The README states the same. This phase must honor it:
- Source **selection UI** is disabled mid-record.
- A device **unplugged** mid-record does **not** trigger session reconfiguration; iOS falls back to the built-in mic and the take continues. Surface a non-blocking warning banner (PromptCam's wording is good: *"External mic disconnected. Recording continues on iPhone mic."*).
- The **meter keeps running** throughout — it reflects whatever is actually being captured.
- Guard at the **service** layer, not just by grey-out.

**D13 — Bluetooth microphones: excluded by default, behind an explicit opt-in.**
Enabling Bluetooth *input* requires adding `.allowBluetooth` (HFP) to the audio-session options. The current config only has `.allowBluetoothA2DP`, which is **output-only** — so BT mics don't appear today. That omission is worth preserving as a default, because enabling HFP:
- collapses capture to narrowband (8/16 kHz) — unacceptable for a cine tool, and
- re-routes *output* to the Bluetooth device, which would **break HDMI audio monitoring** (D4's sibling invariant).

Recommendation: keep `.allowBluetooth` **off** by default and list wired/USB sources only. If BT is ever exposed, it must be an explicit user opt-in with a visible quality warning and a documented note that HDMI audio will be lost. Flag this to the user before implementing rather than silently enabling it.

---

## 2. Phased implementation

### Phase 0 — Pure policy foundation (no behavior change)

_All logic here is value-typed, `nonisolated`, hardware-free, and unit-tested. Mirrors the existing `CapturePolicy.swift` philosophy._

**New file: `Models/CineFormat.swift`** (or append to `CapturePolicy.swift`)

```swift
nonisolated enum CaptureResolution: String, CaseIterable, Codable, Sendable {
    case hd1080 = "HD"
    case uhd4K  = "4K"
    var dimensions: (width: Int32, height: Int32) { ... }   // 1920×1080 / 3840×2160
    var dimensionLabel: String { ... }                       // "1920×1080" / "3840×2160"
}

nonisolated enum CaptureFrameRate: Int, CaseIterable, Codable, Sendable {
    case fps24 = 24
    case fps30 = 30            // NOTE: 60p intentionally excluded this phase
    var displayLabel: String { "\(rawValue)p" }
}

nonisolated struct CineFormat: Equatable, Hashable, Codable, Sendable {
    var resolution: CaptureResolution
    var frameRate: CaptureFrameRate
    static let `default` = CineFormat(resolution: .hd1080, frameRate: .fps30)
}
```

Persistence: `@AppStorage`-compatible. Per project rules **prefer `@AppStorage`** over PromptCam's manual `UserDefaults` + JSON. Store the two enums as two raw-value `@AppStorage` keys (`cineFormat.resolution`, `cineFormat.frameRate`) rather than a JSON blob — simpler, and `@AppStorage` is the mandated mechanism.

**Generalize the selector** — replace `CineHDFormatSelector` with:

```swift
nonisolated enum CaptureFormatSelector {
    static func selectIndex(in formats: [CaptureFormatDescriptor],
                            resolution: CaptureResolution,
                            frameRate: CaptureFrameRate) -> Int?
    /// Highest frame rate from `CaptureFrameRate.allCases` the descriptor supports.
    static func fallbackFrameRate(for descriptor: CaptureFormatDescriptor) -> CaptureFrameRate?
}
```

Keep `CineHDFormatSelector` as a thin deprecated shim _or_ migrate its 6 existing tests — do not delete tested behavior silently.

**New: zoom math (pure).**

```swift
nonisolated struct ZoomPolicy {
    /// deviceFactor -> user-facing multiplier, and back. `multiplier` is
    /// `AVCaptureDevice.displayVideoZoomFactorMultiplier`.
    static func displayed(fromDeviceFactor: CGFloat, multiplier: CGFloat) -> CGFloat
    static func deviceFactor(fromDisplayed: CGFloat, multiplier: CGFloat) -> CGFloat
    static func clamp(_ deviceFactor: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat
    /// Lens preset stops derived from switchover factors + the 1x anchor,
    /// deduped and sorted. Never hardcode [0.5, 1, 2, 3].
    static func presetStops(switchOverFactors: [CGFloat],
                            multiplier: CGFloat,
                            minFactor: CGFloat,
                            maxFactor: CGFloat) -> [CGFloat]
}
```

**New: exposure math (pure).**

```swift
nonisolated enum ExposurePolicy {
    static func clampBias(_ value: Float, min: Float, max: Float) -> Float
}
```

**Tests — `CapturePolicyTests.swift` (extend):** resolution/frame-rate selection incl. 4K, inclusive boundary cases, frame-rate fallback when 4K24 unavailable, zoom round-trip conversion, clamping, preset-stop derivation on representative switchover arrays (`[2.0]`, `[2.0, 6.0]`, `[]`), EV clamp.

**Exit criteria:** `xcodebuild test` green; zero behavior change in the app.

---

### Phase 1 — Multi-lens device + control surface

1. **Device discovery** (`CameraManager.setupSession`): replace the single `AVCaptureDevice.default(.builtInWideAngleCamera, ...)` with a `DiscoverySession` fallback chain (D2). Log which device was selected via `Logger.camera`.
2. **Apply D2a** immediately after the device is set, before `commitConfiguration()`.
3. **Add `Logger.controls`** category to `Logging.swift` (follow the existing `nonisolated static let` style).
4. **Add `@Observable` state to `CameraManager`** (main-actor, mutated only via main hops):
   ```swift
   private(set) var activeFormat: CineFormat
   private(set) var zoomDisplayed: CGFloat          // user-facing, e.g. 1.0 == "1×"
   private(set) var zoomRange: ClosedRange<CGFloat> // displayed units
   private(set) var zoomPresets: [CGFloat]
   private(set) var isFocusLocked: Bool
   private(set) var isExposureLocked: Bool
   private(set) var exposureBias: Float
   private(set) var exposureBiasRange: ClosedRange<Float>
   private(set) var isMultiLensDevice: Bool
   ```
   Seed the ranges on the main hop at the end of `setupSession` (they're device-dependent and unknown until a device exists).
5. **Add a `CameraControlsError`-ish surface** or reuse `lastError` for "can't change format while recording".

**Exit criteria:** app builds and runs identically to today — same 1080p30 framing at 1× (verify on-device that it did _not_ start wide at 0.5×), HDMI unaffected.

---

### Phase 2 — Record Format (4K/HD) + Frame Rate (24p/30p)

**Service (`CameraManager`, new `nonisolated` methods on `sessionQueue`):**

```swift
func setFormat(_ format: CineFormat)          // public, main-actor entry
nonisolated private func applyFormat(_ format: CineFormat, cs: CameraSession)
nonisolated private func reapplyFormatDependentState(cs: CameraSession)   // D9, ordered
```

`applyFormat` must:

- `guard !cs.movieOutput.isRecording` else publish an error and return (D6)
- `beginConfiguration()` / `commitConfiguration()`
- map `device.formats` → `[CaptureFormatDescriptor]`, defer the pick to `CaptureFormatSelector`
- on no exact match: fall back (prefer same resolution at the other frame rate, then HD) and report back what was **actually** applied — never silently claim the requested format
- run `reapplyFormatDependentState` (D9)
- hop to main: update `activeFormat`, persist via `@AppStorage`

**UI — `Views/Camera/FormatControlsView.swift`:**

- Resolution: 2-state toggle button `HD | 4K` (user asked for a toggle button, not a picker)
- Frame rate: segmented `24p | 30p` — **no 60p**
- A compact status pill in the chrome reading e.g. `4K · 24p`, mirroring PromptCam's `CameraTopControlsView` format pill
- `.disabled(cameraManager.isRecording)` + `.opacity(isRecording ? 0.3 : 1.0)` + `.animation(.easeInOut(duration: 0.2), value:)`

**Also:** apply D4 here (HDMI pinned to 1080p), since this is the phase that makes 4K reachable. Update `README.md` in the same phase to document the always-1080p HDMI invariant.

**Tests:** selector-level unit tests (Phase 0 covers most); add a test that the fallback chain returns a _reported_ format equal to what the selector could satisfy.

**Manual validation:** switch HD↔4K and 24↔30 with an HDMI monitor attached; confirm (a) HDMI keeps a stable 1080p image, (b) recorded file is genuinely 4K when selected, (c) switching is rejected mid-record.

---

### Phase 3 — Zoom control

**Service:**

```swift
func setZoom(displayed: CGFloat)                       // absolute, from slider/preset
func rampZoom(toDisplayed: CGFloat, rate: Float)       // smooth, for preset taps
nonisolated private func applyZoom(...)                // sessionQueue + lockForConfiguration
```

- Convert displayed → device factor via `ZoomPolicy` + `displayVideoZoomFactorMultiplier`
- Clamp to `device.minAvailableVideoZoomFactor ... device.maxAvailableVideoZoomFactor`
  (use the _available_ variants, not `videoMaxZoomFactor` — they account for the active format)
- Use `device.ramp(toVideoZoomFactor:withRate:)` for preset taps (smooth, cine-appropriate), direct assignment for continuous slider/pinch drag
- Cancel an in-flight ramp (`cancelVideoZoomRamp()`) if the user grabs the slider mid-ramp
- Zoom **remains enabled during recording** (D6)

**UI — `Views/Camera/ZoomControlView.swift`:**

- Lens preset capsule row built from `cameraManager.zoomPresets` (derived, never hardcoded), active stop highlighted
- Continuous fine control: a slider (or pinch `MagnifyGesture` on the preview) spanning `zoomRange`
- Live readout `1.0×` style, formatted to 1 decimal
- Hide/disable the preset row when `!isMultiLensDevice`

**Gotcha:** re-clamp and re-publish `zoomRange`/`zoomPresets` after every format change (D9) — the available zoom range differs between HD and 4K formats.

---

### Phase 4 — Focus / Auto-Focus toggle

**Preview plumbing (D5):** add to `CameraPreview.PreviewUIView`:

```swift
func devicePoint(for layerPoint: CGPoint) -> CGPoint? {
    previewLayer?.captureDevicePointConverted(fromLayerPoint: layerPoint)
}
```

Wire a tap recognizer in `makeUIView` and forward the converted point through the `Coordinator` to `CameraManager`. **Do not** compute normalized coordinates in SwiftUI.

**Service:**

```swift
func focus(at devicePoint: CGPoint)        // tap-to-focus: .autoFocus at point
func setAutoFocus(_ enabled: Bool)         // toggle: .continuousAutoFocus <-> .locked
```

Guard every capability with `isFocusModeSupported(_:)` / `isFocusPointOfInterestSupported`. Follow PromptCam's lock/unlock semantics but keep focus and exposure **independently togglable** (PromptCam combines them; the user explicitly asked for separate Focus and Exposure controls).

**UI:** an `AF`/`MF` toggle badge modeled on `CameraLockStatusBadgeView` (white = auto, yellow = locked, red/disabled = unsupported), plus a brief focus-reticle animation at the tap point.

---

### Phase 5 — Exposure / Auto-Exposure + EV bias

**Service:**

```swift
func setAutoExposure(_ enabled: Bool)      // .continuousAutoExposure <-> .locked
func setExposureBias(_ ev: Float)          // absolute, clamped
func adjustExposureBias(by delta: Float)   // incremental
func resetExposureBias()                   // -> 0.0
func exposeAndMeter(at devicePoint: CGPoint)
```

Clamp through `ExposurePolicy.clampBias` against `device.min/maxExposureTargetBias`; apply with `setExposureTargetBias(_:completionHandler:)` inside a config lock.

**UI — `Views/Camera/ExposureControlView.swift`:** modeled on PromptCam's `EVAdjustmentPanel` — a slider over `±exposureBiasRange`, `0.1` EV steps, tick marks at min/0/max, a Reset button, and an `AE`/locked badge. EV bias stays live during recording.

---

### Phase 6 — UI assembly, theming, accessibility

1. **`Views/Camera/CameraLayout.swift`** — geometry constants; compute the letterbox bar heights from the active format's aspect vs. container size so chrome lands in the bars (D7).
2. **`Views/Components/ControlPanel.swift`** — port PromptCam's `StandardPanel` shape (title + icon + close, 16pt radius, 1pt `white.opacity(0.12)` border, dark gradient, scrim, `.transition(.scale(scale: 0.95).combined(with: .opacity))`, optional auto-dismiss).
3. **`App/Theme.swift`** — port the token set (accent, panel bg, radii, `panelSpring`). Note PromptCam deliberately avoids SwiftUI materials.
4. **Refactor `ContentView.cameraView`** into `CameraScreen` composing: preview (unchanged `.resizeAspect`, still `.ignoresSafeArea()`), control chrome, record cluster.
5. **Accessibility (mandatory per project rules — route through `mobile-a11y-specialist`):** every control gets `.accessibilityLabel` + `.accessibilityValue` (e.g. "Zoom, 2.0×"); sliders get `.accessibilityAdjustableAction`; the format toggle announces its new state; focus/exposure badges expose `.isSelected` traits; verify Dynamic Type doesn't break the letterbox chrome; ensure a 44×44pt minimum hit target.

**Exit criteria:** `xcodebuild` clean; manual on-device pass with HDMI attached; preview still uncropped at both HD and 4K in portrait _and_ landscape.

---

### Phase 7 — External audio sources + VU metering

_Largely independent of Phases 2–5 (no shared device-configuration surface), so it can run in parallel with the camera-control work or be pulled forward. It does depend on Phase 6's panel/theme components for its UI, and on **D11's refactor** landing first._

#### 7a — Refactor the audio tap to be permanent (prerequisite)

Per D11, `AudioMirror` currently installs the session's only `AVCaptureAudioDataOutput` on HDMI connect. Invert that:

1. Add the audio data output **once, in `CameraManager.setupSession`**, alongside `movieOutput` / `videoDataOutput` (guarded by `canAddOutput`).
2. Keep the existing `processingQueue` as the delegate queue — do **not** reuse `sessionQueue` or `videoDataOutputQueue` (the frame-drop lesson in `CameraManager.swift` applies here too).
3. `ExternalDisplayController.enableAudioMirroring()` / `disableAudioMirroring()` now only toggle a `isPlaybackEnabled` flag (and the engine lifecycle), not session membership.
4. Preserve the existing `.AVAudioEngineConfigurationChange` rebuild — it's load-bearing against the documented stale-graph crashes.

**Exit criteria:** HDMI audio still works exactly as before on connect/disconnect, with no change in behavior. This step ships nothing user-visible.

#### 7b — Pure metering policy + tests

**New file: `AudioPolicy.swift`** — hardware-free, `nonisolated`, unit-tested (same philosophy as `CapturePolicy.swift`):
```swift
nonisolated enum AudioLevelPolicy {
    static let silenceFloorDb: Float = -60
    /// dBFS -> 0...1, clamped. (db + 60) / 60
    static func normalize(db: Float) -> Float
    static func decibels(fromRMS rms: Float) -> Float     // rms > 0 ? 20*log10(rms) : floor
    /// Peak ballistics: instant attack, `holdDuration` plateau, then decay
    /// `decayRate` of the remaining delta per buffer.
    static func nextPeak(current: Float, level: Float,
                         lastPeakAt: TimeInterval, now: TimeInterval,
                         holdDuration: TimeInterval = 1.5,
                         decayRate: Float = 0.15) -> (peak: Float, peakAt: TimeInterval)
}

nonisolated enum AudioSourcePolicy {
    /// Ordering + filtering of selectable ports. Excludes Bluetooth unless
    /// `allowBluetooth` (D13). Pure: operates on a value-typed port summary.
    static func selectable(from ports: [AudioPortSummary], allowBluetooth: Bool) -> [AudioPortSummary]
    static func displayName(for port: AudioPortSummary, captureDeviceName: String?) -> String
    static func iconName(for port: AudioPortSummary) -> String
}

nonisolated struct AudioPortSummary: Equatable, Sendable {
    let uid: String
    let portName: String
    let portTypeRawValue: String   // keeps the policy free of AVFoundation objects
    var isExternal: Bool
}
```

**Tests (`AudioPolicyTests.swift`):** −60/0/+clamp normalization boundaries, `rms == 0` → floor, peak attack/hold/decay across a simulated timeline, Bluetooth filtered out when `allowBluetooth == false`, display-name fallback when no capture-device name resolves, icon mapping per port type.

#### 7c — Metering in the existing delegate

In the (renamed) audio tap's `captureOutput(_:didOutput:from:)`:
- Convert the `CMSampleBuffer` to float samples (the existing `makePCMBuffer` helper already does the heavy lifting).
- `vDSP_rmsqv` per channel → `AudioLevelPolicy.decibels` → `normalize`.
- `vDSP_maxmgv` for peak amplitude (drives the silence watchdog, per PromptCam — peak, **not** RMS, so quiet room tone isn't flagged as a dead mic).
- Detect stereo from `format.channelCount >= 2`; meter channels independently.
- **Rate-limit publication to 30 fps** before hopping to main — do not post per-buffer (~86/sec at 1024 frames @ 44.1 kHz). This matters: the existing codebase already has a documented incident where over-eager per-frame work on a delegate queue caused a feedback loop of drops.
- Publish via `DispatchQueue.main.async` into `@Observable` state, matching D8.

#### 7d — Source discovery, selection, and route monitoring

**`CameraManager` (or a focused `AudioSourceController` it owns):**
```swift
private(set) var availableAudioInputs: [AudioInputOption]   // UI-facing value type
private(set) var activeAudioInputName: String?
private(set) var audioLevel: Float          // 0...1, channel 1
private(set) var audioPeak: Float
private(set) var audioLevel2: Float?        // nil == mono
private(set) var audioPeak2: Float?
private(set) var audioWarning: String?      // disconnect / silence banner

func refreshAudioInputs()
func selectAudioInput(_ option: AudioInputOption?)   // nil == system default
```
- Enumerate `AVAudioSession.availableInputs`, map to `AudioPortSummary`, filter/sort via `AudioSourcePolicy`.
- Resolve friendlier names via `AVCaptureDevice.DiscoverySession` keyed by `uniqueID` (D10).
- Apply with `setPreferredInput(_:)`; then, **only if `!movieOutput.isRecording`** (D12), re-create the audio `AVCaptureDeviceInput` on `sessionQueue` inside `beginConfiguration`/`commitConfiguration` so the session re-resolves the route.
  - ⚠️ PromptCam removes the old input *before* validating the new one and has **no rollback**. Don't copy that: build and validate the replacement first, and restore the previous input if `canAddInput` fails.
- Allow the route to settle before restarting dependent audio (PromptCam uses ~0.8 s); coalesce rapid changes with a debounced, cancellable `Task`.

**Route monitoring — hybrid, not either/or:**
- Observe `AVAudioSession.routeChangeNotification` for prompt reaction, **and** keep a 1 Hz poll comparing `currentRoute.inputs.first?.uid` plus the set of `availableInputs` UIDs. PromptCam found notifications unreliable for USB interfaces enumerating as `"Other"`; the poll is the safety net, the notification is the fast path. Both funnel into one idempotent handler.
- Observe `AVAudioSession.interruptionNotification` for calls/Siri.
- Remember the user's chosen UID so a device that disappears is reclaimed automatically when it returns.
- Persist the preference with `@AppStorage` (project rule; PromptCam only keeps it in memory). Store the port **UID**, treat it as a hint, and fall back silently to the system default when it no longer resolves.

#### 7e — UI

**`Views/Camera/VUMeterView.swift`** — port PromptCam's vertical meter:
- Continuous gradient fill (not segments), bottom→top; peak drawn as a horizontal line
- dB hash marks at normalized `1.0 / 0.9 / 0.8 / 0.667 / 0.5 / 0.333` → `0 / −6 / −12 / −20 / −30 / −40`
- Second bar + 3 pt gap when stereo; channels never summed
- `CLIP` badge latched at `>= 0.98`
- `.animation(.linear(duration: 0.05), value:)` on level and peak
- Lives in the letterbox chrome (D7), sized by its parent

**`Views/Camera/AudioSourcePickerView.swift`** — list of `AudioInputOption` with SF Symbol per port type (`iphone`, `headphones`, `cable.connector`), active row checked, "System Default" entry mapping to `nil`. Present in the Phase 6 `ControlPanel`. `.disabled(isRecording)` (D12).

**Warning banner** — transient, non-blocking, for mid-record disconnect and the silence watchdog.

**Accessibility (mandatory):** the VU meter is decorative-but-informative — give it `.accessibilityLabel("Audio level")` with a `.accessibilityValue` in dB and **do not** let it spam VoiceOver at 30 fps (throttle announcements, or mark it `.accessibilityHidden` and expose a separate summarized value). Picker rows need `.isSelected` traits. Route this through `mobile-a11y-specialist`.

**Exit criteria:** meter responds with no HDMI attached; USB mic appears, is selectable, and survives unplug/replug; switching is blocked mid-record with a warning; HDMI audio monitoring still works; `Logger.externalDisplay` shows no new frame-drop pressure.

---

### Phase 8 — Deferred (next cycle)

ISO and shutter speed via `setExposureModeCustom(duration:iso:completionHandler:)`, with ranges from `activeFormat.minISO/maxISO` and `minExposureDuration/maxExposureDuration`. PromptCam implements **neither** — no reference available. Design note: manual shutter must be re-clamped on every format/frame-rate change, since max duration is bounded by frame interval (e.g. 1/24s floor at 24p).

Also deferred: audio **input gain** (`AVAudioSession.setInputGain`, only valid when `isInputGainSettable`), and per-channel/stereo source selection via `AVAudioSessionPortDescription.dataSources` (useful for the iPhone's directional built-in mics).

---

## 3. Risk register

| #   | Risk                                                                                     | Mitigation                                                                                               |
| --- | ---------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| R1  | Switching to a virtual device silently changes framing to 0.5×                           | D2a — explicitly set the 1× anchor on configure; verify on-device in Phase 1 before moving on            |
| R2  | 4K sample buffers overwhelm the HDMI path (existing drop logging already shows pressure) | D4 — HDMI pinned to 1080p always; watch `Logger.externalDisplay` drop counters during Phase 2 validation |
| R3  | Format change silently resets frame rate / zoom / codec / HDMI settings                  | D9 — one ordered `reapplyFormatDependentState` method; never apply piecemeal                             |
| R4  | Tap-to-focus lands on the wrong subject because of letterbox bars                        | D5 — `captureDevicePointConverted(fromLayerPoint:)` only; never manual normalization                     |
| R5  | Reintroducing preview cropping while making room for chrome                              | D7 — chrome overlays the letterbox bars; `.resizeAspect` must not change                                 |
| R6  | Mid-recording reconfiguration corrupts the capture                                       | D6 — service-level guard, not just a disabled button                                                     |
| R7  | Device lacks requested format (e.g. no 4K24)                                             | Fallback chain that reports the format _actually_ applied back to the UI                                 |
| R8  | `sessionPreset` silently overriding `activeFormat`                                       | D1 — never assign `sessionPreset`                                                                        |
| R9  | Not every device is a triple-camera                                                      | Discovery fallback chain; `isMultiLensDevice` gates the preset row                                       |
| R10 | Second `AVCaptureAudioDataOutput` silently fails to add (`canAddOutput == false`)        | D11 — reuse `AudioMirror`'s existing output; never add a second. Assert/log if `canAddOutput` is false   |
| R11 | Audio-tap refactor (7a) regresses HDMI audio, which has documented stale-graph crashes   | 7a ships with **no** user-visible change and is validated on its own; preserve the `ConfigurationChange` rebuild |
| R12 | Per-buffer metering work floods the delegate queue (prior drop-feedback-loop incident)   | 7c — rate-limit publication to 30 fps before the main hop; watch `Logger.externalDisplay` counters       |
| R13 | USB interfaces enumerating as port type `"Other"` never fire `routeChangeNotification`   | 7d — hybrid notification **+** 1 Hz poll into one idempotent handler (PromptCam's production finding)    |
| R14 | Audio input swap removes the old input and fails to add the new one, leaving no audio    | 7d — validate the replacement before removing; roll back on failure (PromptCam has no rollback — don't copy) |
| R15 | Enabling Bluetooth mics narrowbands capture **and** steals output from HDMI              | D13 — `.allowBluetooth` stays off by default; opt-in only, with an explicit warning                      |

---

## 4. Validation per phase

- **Unit:** `xcodebuild test -scheme CineVideoApp` — all new policy logic is pure and must be covered (Swift Testing style, matching `CapturePolicyTests.swift`).
- **Build:** `xcodebuild -scheme CineVideoApp -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build`
- **On-device manual:** HDMI monitor attached — check framing, uncropped preview, format switching, zoom through all lenses, tap-to-focus accuracy near frame edges, EV response, that all format controls are inert mid-record, and that **the HDMI feed stays 1080p while recording 4K** (D4).
- **On-device manual (audio, Phase 7):** requires a real USB-C mic/interface **and** a USB-C hub to exercise mic + HDMI simultaneously (an open hardware question already tracked in `mvp-plan.md`). Verify: meter moves with no monitor attached; USB mic appears and is selectable; unplug/replug restores the preference; unplug **during** a take continues recording on the built-in mic with a warning and no session reconfiguration; HDMI audio still plays; recorded file's audio track matches the metered source.

## 5. Agent routing (per project rules)

`swift-lead` orchestrates. Expected specialists: `swiftui-specialist` (Phases 2–6 UI, 7e), `concurrency-specialist` (Phases 1–5 and **7a/7c especially** — the audio tap crosses `sessionQueue`, a private delegate queue, and the main actor), `mobile-a11y-specialist` (Phase 6 and 7e meter/picker, mandatory), `testing-specialist` (Phase 0 and 7b test design), `performance-specialist` (R2 and R12 — frame/buffer drop validation).

**Standing constraints:** no mock/stub/placeholder implementations; `@Observable` only (never `ObservableObject`); `@AppStorage` for persistence; built-in SwiftUI controls over custom replacements; `OSLog` not `print()`.
