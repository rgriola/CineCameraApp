# CineCameraApp — Camera & Format Controls Extension Plan

**Target:** iOS 18.0+ · Swift 6 · SwiftUI (no UIKit chrome) · AVFoundation
**Scope of this plan:** Record Format (4K/HD), Frame Rate (24p/30p), Zoom, Focus/AF, Exposure/AE
**Deferred to a later phase:** ISO, Shutter Speed

---

## 0. Baseline — what exists today

| Concern | Current state | File |
| --- | --- | --- |
| State container | `@Observable final class CameraManager: NSObject`, singleton `.shared` | `CameraManager.swift:229` |
| AVFoundation ownership | `private final class CameraSession: NSObject, @unchecked Sendable`, all fields `nonisolated(unsafe)`, owned by `sessionQueue` | `CameraManager.swift:19` |
| Threading | Serial `sessionQueue`; separate `videoDataOutputQueue` for sample buffers; `DispatchQueue.main.async` hops to mutate `@Observable` state | `CameraManager.swift` |
| Device | `AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)` — **single lens, no zoom possible** | `CameraManager.swift:478` |
| Format | Hardcoded 1920×1080@30 via `applyCineHDFormat` | `CameraManager.swift:557` |
| Format policy | Pure, unit-tested `CineHDFormatSelector` / `CaptureFormatDescriptor` / `CodecSelector` | `CapturePolicy.swift` |
| Preview | `CameraPreview: UIViewRepresentable` + `PreviewUIView` + per-preview `RotationCoordinator` | `CameraPreview.swift` |
| Preview gravity | `.resizeAspect` (letterboxed, uncropped — fixed this session) | `CameraPreview.swift:133` |
| HDMI out | `videoDataOutput` → `ExternalDisplayController` → `AVSampleBufferDisplayLayer` (`.resizeAspect`), locked to landscape 0° | `ExternalDisplayController.swift` |
| UI | `ZStack(alignment: .bottom)` with preview + a single record button | `ContentView.swift:46` |
| Tests | Swift Testing (`import Testing`, `@Test`, `#expect`) | `CapturePolicyTests.swift` |
| Logging | `Logger.camera` / `.recording` / `.permissions` / `.externalDisplay` / `.orientation` | `Logging.swift` |

### What PromptCam actually gives us

Researched `/promptcam-fixer`. Reusable patterns:

- `RecordingFormat` value model — `Codable`/`Sendable` struct of independent enums, `.default`, `loadSaved()`/`save()` (`Models/RecordingFormat.swift`)
- `applyFormat` guard pattern — reject format changes while `movieFileOutput.isRecording` (`Services/CameraService+Format.swift:14-25`)
- Frame-rate fallback — probe `activeFormat.videoSupportedFrameRateRanges`, degrade to highest supported (`CameraService+Format.swift:491-518`)
- Combined focus+exposure point/lock semantics, `.locked` ⇄ `.continuousAuto*` (`Services/CameraService+Controls.swift:37-190`)
- EV bias clamped to `device.min/maxExposureTargetBias` (`CameraService+Controls.swift:158-196`)
- `StandardPanel` overlay container + `Theme` tokens; controls `.disabled(isRecording).opacity(isRecording ? 0.3 : 1.0)`

**Critical gap:** *PromptCam implements no zoom at all.* No `videoZoomFactor`, no pinch gesture, no lens switching — it is a selfie-cam app on a single front lens. **The entire zoom feature must be designed from scratch here.** Do not go looking for a PromptCam reference implementation.

Also note PromptCam uses `sessionPreset` for its Standard mode — **we deliberately diverge** (see Decision D1).

---

## 1. Key design decisions (read before coding)

**D1 — Keep `activeFormat` selection; never set `sessionPreset`.**
CineCameraApp needs deterministic cine formats, and already has a tested pure selector. Setting `device.activeFormat` implicitly moves the session to `.inputPriority`. Do **not** assign `session.sessionPreset` anywhere afterward — it would silently override the chosen format.

**D2 — Upgrade the capture device to a virtual multi-lens device.** Zoom across "a wide range of focal lengths" is impossible on `.builtInWideAngleCamera`. Use an `AVCaptureDevice.DiscoverySession` fallback chain:
`.builtInTripleCamera` → `.builtInDualWideCamera` → `.builtInDualCamera` → `.builtInWideAngleCamera`.

**D2a — ⚠️ Framing regression hazard.** On a virtual device, `videoZoomFactor == 1.0` is the **ultra-wide** lens (UI "0.5×"), *not* 1×. If we switch device without compensating, the app silently starts at 0.5× — a visible regression. On first configure, set the initial zoom to the 1× equivalent:
```swift
device.videoZoomFactor = 1.0 / device.displayVideoZoomFactorMultiplier
```

**D3 — Use `displayVideoZoomFactorMultiplier` (iOS 18+) for zoom labels.** Verified available on our deployment target. `displayedZoom = videoZoomFactor * device.displayVideoZoomFactorMultiplier`, and inversely `videoZoomFactor = displayedZoom / multiplier`. This replaces the old hardcoded per-device mapping tables. Derive lens-preset buttons from `virtualDeviceSwitchOverVideoZoomFactors` (converted through the same multiplier) so presets are correct on every device instead of hardcoded 0.5/1/2/3.

**D4 — 🔒 PROJECT INVARIANT: HDMI output is ALWAYS 1080p.**
The external monitor feed is fixed at 1920×1080 regardless of the selected recording format. It is **not** user-configurable and must never track the record resolution. This sits alongside the existing HDMI invariant that the feed is always fixed-landscape (`lockHDMIToLandscape`) — together they define the external feed as a *stable monitoring signal*, decoupled from whatever the recording is doing. This mirrors Blackmagic Camera's behavior and protects a path that already logs `FrameWasLate`/`OutOfBuffers` pressure at 1080p.

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
- Format + frame rate: **hard-blocked** while `movieOutput.isRecording` (matches the existing `setupSession` guard and PromptCam). Grey out in UI *and* reject in the service.
- Zoom / focus / exposure: **allowed live** — this is a cine app; operators pull focus and zoom mid-take.
- Orientation remains locked during recording (existing behavior, untouched).

**D7 — Place chrome in the letterbox bars.** With `.resizeAspect` + a 16:9 frame on a ~19.5:9 screen there are substantial black bars. Put controls there so they never cover image. Do **not** reintroduce cropping or shrink the preview to make room.

**D8 — Concurrency: follow the existing pattern exactly.** Every device mutation is a `nonisolated` method dispatched on `sessionQueue`, wrapped in `lockForConfiguration()` / `defer { unlockForConfiguration() }`, pushing results back via `DispatchQueue.main.async`. Do **not** introduce actors, `ObservableObject`, or a new queue. Per project rules: `@Observable` only.

**D9 — Format change invalidates dependent state.** After any `activeFormat` assignment you must, in order: re-apply frame rate → re-clamp and re-apply zoom (`videoMaxZoomFactor` changes per format) → re-apply `videoDataOutput.videoSettings` (D4) → re-verify the HEVC codec on the movie connection. Encode this as one ordered private method so it can't be done piecemeal.

---

## 2. Phased implementation

### Phase 0 — Pure policy foundation (no behavior change)

*All logic here is value-typed, `nonisolated`, hardware-free, and unit-tested. Mirrors the existing `CapturePolicy.swift` philosophy.*

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
Keep `CineHDFormatSelector` as a thin deprecated shim *or* migrate its 6 existing tests — do not delete tested behavior silently.

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

**Exit criteria:** app builds and runs identically to today — same 1080p30 framing at 1× (verify on-device that it did *not* start wide at 0.5×), HDMI unaffected.

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

**Tests:** selector-level unit tests (Phase 0 covers most); add a test that the fallback chain returns a *reported* format equal to what the selector could satisfy.

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
  (use the *available* variants, not `videoMaxZoomFactor` — they account for the active format)
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

**Exit criteria:** `xcodebuild` clean; manual on-device pass with HDMI attached; preview still uncropped at both HD and 4K in portrait *and* landscape.

---

### Phase 7 — Deferred (next cycle)

ISO and shutter speed via `setExposureModeCustom(duration:iso:completionHandler:)`, with ranges from `activeFormat.minISO/maxISO` and `minExposureDuration/maxExposureDuration`. PromptCam implements **neither** — no reference available. Design note: manual shutter must be re-clamped on every format/frame-rate change, since max duration is bounded by frame interval (e.g. 1/24s floor at 24p).

---

## 3. Risk register

| # | Risk | Mitigation |
| --- | --- | --- |
| R1 | Switching to a virtual device silently changes framing to 0.5× | D2a — explicitly set the 1× anchor on configure; verify on-device in Phase 1 before moving on |
| R2 | 4K sample buffers overwhelm the HDMI path (existing drop logging already shows pressure) | D4 — HDMI pinned to 1080p always; watch `Logger.externalDisplay` drop counters during Phase 2 validation |
| R3 | Format change silently resets frame rate / zoom / codec / HDMI settings | D9 — one ordered `reapplyFormatDependentState` method; never apply piecemeal |
| R4 | Tap-to-focus lands on the wrong subject because of letterbox bars | D5 — `captureDevicePointConverted(fromLayerPoint:)` only; never manual normalization |
| R5 | Reintroducing preview cropping while making room for chrome | D7 — chrome overlays the letterbox bars; `.resizeAspect` must not change |
| R6 | Mid-recording reconfiguration corrupts the capture | D6 — service-level guard, not just a disabled button |
| R7 | Device lacks requested format (e.g. no 4K24) | Fallback chain that reports the format *actually* applied back to the UI |
| R8 | `sessionPreset` silently overriding `activeFormat` | D1 — never assign `sessionPreset` |
| R9 | Not every device is a triple-camera | Discovery fallback chain; `isMultiLensDevice` gates the preset row |

---

## 4. Validation per phase

- **Unit:** `xcodebuild test -scheme CineVideoApp` — all new policy logic is pure and must be covered (Swift Testing style, matching `CapturePolicyTests.swift`).
- **Build:** `xcodebuild -scheme CineVideoApp -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build`
- **On-device manual:** HDMI monitor attached — check framing, uncropped preview, format switching, zoom through all lenses, tap-to-focus accuracy near frame edges, EV response, that all format controls are inert mid-record, and that **the HDMI feed stays 1080p while recording 4K** (D4).

## 5. Agent routing (per project rules)

`swift-lead` orchestrates. Expected specialists: `swiftui-specialist` (Phases 2–6 UI), `concurrency-specialist` (Phases 1–5 — every `sessionQueue`/`nonisolated`/`Sendable` boundary), `mobile-a11y-specialist` (Phase 6, mandatory), `testing-specialist` (Phase 0 test design), `performance-specialist` (R2, 4K frame-drop validation).

**Standing constraints:** no mock/stub/placeholder implementations; `@Observable` only (never `ObservableObject`); `@AppStorage` for persistence; built-in SwiftUI controls over custom replacements; `OSLog` not `print()`.
