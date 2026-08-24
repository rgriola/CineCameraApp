# DI Refactor — Unlock Unit Testing of Capture Logic (Phase 0 + Phase 1)

**Branch:** `refactor/di-unlock-testing`
**Scope:** Phase 0 (extract pure policy) + Phase 1 (permission-cascade seam). Phases 2-3 are explicitly out of scope for this branch.
**Goal:** Make the app's capture _decision logic_ unit-testable without real camera/mic/Photos hardware, by separating **policy** (pure decisions) from **mechanism** (AVFoundation calls) — without changing production behavior or destabilizing the working capture/HDMI pipeline.

---

## Guiding principles

1. **Policy vs. mechanism.** Pure decisions become value-typed, `nonisolated`, side-effect-free functions tested directly. Hardware calls go behind thin protocol seams.
2. **No mocks in app code.** Per the project's swift-lead rule, every line of _app_ code is real and functional. Test doubles (stubs/spies/fakes) live **only in the test target** (`CineVideoAppTests`). Production always wires the real system-backed implementations via default initializer arguments.
3. **Behavior-preserving.** The app compiles and runs identically after each phase. Constructor injection uses production defaults so `CameraManager.shared`, `ExternalDisplayController`, and the scene delegate are unaffected.
4. **Ship per phase.** Each phase is its own commit, kept green (build + tests) before moving on.
5. **Do NOT touch** `ExternalDisplayController` (UIWindow + `AVSampleBufferDisplayLayer`) or `AudioMirror` (`AVAudioEngine`). They are hardware/view glue with negligible testable policy; abstracting them is high-cost, low-value, and risks the working HDMI feed.

---

## Phase 0 — Extract pure policy (no DI, highest ROI, near-zero risk)

Pull decision logic out of the hardware methods into pure functions over **value inputs**. No protocols. The app calls the new functions from the same call sites; the surrounding AVFoundation code is unchanged.

### 0.1 Codec selection

- **Extract from:** `applyHEVCCodec(cs:)` (CameraManager.swift, ~L574).
- **New (app):** `CodecSelector.select(from available: [AVVideoCodecType]) -> AVVideoCodecType` — prefers `.hevc`, falls back to `.h264`.
- **Why testable:** `AVVideoCodecType` is a Sendable value type, constructible in tests. No hardware needed.
- **Call site change:** `applyHEVCCodec` computes the codec via `CodecSelector.select(from: cs.movieOutput.availableVideoCodecTypes)` then applies it. Same behavior.

### 0.2 Cine-HD format selection

- **Extract from:** `applyCineHDFormat(to:)` (CameraManager.swift, ~L544).
- **New (app):**
  - `struct CaptureFormatDescriptor: Sendable, Equatable { let width: Int32; let height: Int32; let frameRateRanges: [ClosedRange<Double>] }`
  - `enum CineHDFormatSelector { static func selectIndex(in formats: [CaptureFormatDescriptor], targetFrameRate: Double) -> Int? }` (returns the index of the first 1920x1080 format supporting the target fps, else `nil`).
- **Why testable:** production maps each real `AVCaptureDevice.Format` -> `CaptureFormatDescriptor`; the _selection_ logic runs on synthetic descriptors in tests.
- **Call site change:** `applyCineHDFormat` builds descriptors from `device.formats`, calls the selector, and applies `device.formats[index]`. Same behavior + same fallback log.

### 0.3 Recording URL generation (light)

- **Extract from:** `performToggleRecording(cs:)` (CameraManager.swift, ~L642).
- **New (app):** `enum RecordingURL { static func makeTemporaryMovieURL() -> URL }` (UUID + `.mov` in the temp dir).
- **Why testable:** pure; assert extension is `mov`, directory is the temp dir, and successive calls are unique.

### Phase 0 tests (in `CineVideoAppTests`)

- `CodecSelectorTests` — parameterized: `[.hevc, .h264]` -> `.hevc`; `[.h264]` -> `.h264`; empty -> `.h264` (documents the fallback contract).
- `CineHDFormatSelectorTests` — parameterized: exact 1080p@30 present -> its index; 1080p present but only @24 -> `nil`; no 1080p -> `nil`; multiple matches -> first index.
- `RecordingURLTests` — extension/dir/uniqueness.

**Risk:** minimal (mechanical extraction). **Payoff:** immediate tests for the two most bug-prone "which one do we pick" decisions.

---

## Phase 1 — Permission-cascade seam (highest-value DI, medium risk)

The permission cascade is _real sequencing logic_ — order (camera -> mic -> photo), no-op when already granted, and short-circuit on denial — currently untestable because it calls static `AVCaptureDevice`/`PHPhotoLibrary` APIs and hops on `DispatchQueue.main`.

**Cascade call chain today:**
`checkPermissions()` (L323) -> `checkMicrophonePermission()` (L391) -> `checkPhotoLibraryPermission()` (L414) -> `startSessionIfAuthorized()` (L436), all in CameraManager.swift.

### 1.1 Define the seam (app)

```
protocol PermissionsService: Sendable {
    func cameraStatus() -> AVAuthorizationStatus
    func requestCamera() async -> Bool
    func micStatus() -> AVAuthorizationStatus
    func requestMic() async -> Bool
    func photoStatus() -> PHAuthorizationStatus
    func requestPhoto() async -> PHAuthorizationStatus
}
```

### 1.2 Real conformance (app)

- `struct SystemPermissionsService: PermissionsService` wrapping `AVCaptureDevice.authorizationStatus(for:)` / `requestAccess(for:)` and `PHPhotoLibrary.authorizationStatus(for:)` / `requestAuthorization(for:)`.

### 1.3 Injection (app)

- `CameraManager(permissions: PermissionsService = SystemPermissionsService())`.
- `static let shared = CameraManager()` keeps the default -> `ExternalDisplayController` and the scene delegate are unaffected.

### 1.4 Convert the cascade to async/await (app)

- Replace the completion-handler chain with a single `async` flow driving the injected service; update `@MainActor @Observable` state on the main actor after each `await`. This removes the `DispatchQueue.main.async` hops in the cascade and makes ordering deterministic. (Does **not** change the `setupSession`/sessionQueue capture path.)

### Phase 1 tests (in `CineVideoAppTests`)

- `StubPermissionsService` (test target only) — scriptable statuses + records which requests were made, in order.
- `PermissionCascadeTests`:
  - Requests in order camera -> mic -> photo when all `.notDetermined`.
  - Skips a stage already `.authorized` (no redundant request).
  - A `.denied`/`.restricted` at any stage stops the cascade and never starts the session.
  - Final `isAuthorized` / `permissionsDenied` reflect the scripted end state.
  - `.limited` photo status -> authorized path.

**Risk:** medium — touches `CameraManager` init and the permission methods. Contained, and it covers the single most logic-heavy untested area.
**WARNING - Concurrency-sensitive** (async conversion + `Sendable` protocol): request a **concurrency-specialist review** before merging Phase 1.

---

## Recommendations

- **Do Phase 0 first, in one commit**, and get it green before touching permissions. It's pure upside with negligible risk and gives us tests immediately.
- **Then Phase 1**, in its own commit, with a concurrency review before merge.
- Keep `SWIFT_VERSION = 5.0` for now; the Phase 1 async conversion moves us _toward_ Swift 6 but flipping the language mode stays a separate, later decision.
- **Stop after Phase 1.** That's the ROI knee. Phases 2 (Photos save seam) and 3 (capture-session lifecycle) are deferred and not part of this branch.
- Follow the validation loop each phase: **build -> run tests -> only then proceed.**

---

## Checklist to follow AFTER Phase 0 is implemented

Do these in order once Phase 0's code + tests are written:

- [ ] **Build the app target** (Swift 5 mode) — confirms extractions compile with no behavior change.
- [ ] **Run the full test suite** on a simulator (e.g. iPhone 17 Pro): `xcodebuild test -project CineVideoApp.xcodeproj -scheme CineVideoApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`. Confirm the new `CodecSelectorTests`, `CineHDFormatSelectorTests`, and `RecordingURLTests` pass alongside the existing permission/rotation tests.
- [ ] **Sanity-check call sites**: `applyHEVCCodec`, `applyCineHDFormat`, and `performToggleRecording` now delegate to the pure helpers and still produce identical results/log lines.
- [ ] **On-device smoke test** (real hardware): launch, confirm 1080p30 HEVC recording still works and the HDMI clean feed is unchanged. (Format/codec selection is the changed logic — verify the picked format/codec matches before.)
- [ ] **Commit Phase 0** on `refactor/di-unlock-testing` with a message scoped to "extract pure codec/format/URL policy + tests" (include the `Co-authored-by` trailer).
- [ ] **Confirm working tree is clean** and the branch builds green before starting Phase 1.
- [ ] **Green-light Phase 1**: only begin the permission-cascade seam once Phase 0 is committed and verified. Plan for a concurrency-specialist review of the async conversion before Phase 1 merges.

---

## Out of scope for this branch (recorded for later)

- **Phase 2** — `PhotoLibrarySaving` seam for the Photos save/gating path.
- **Phase 3** — `CaptureSessionControlling` lifecycle abstraction (recommended: narrow, recording-only, or skip).
- Any changes to `ExternalDisplayController` or `AudioMirror`.
- Flipping `SWIFT_VERSION` to 6.
