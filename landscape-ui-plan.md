# Landscape Camera UI Rework

Status: landscape implementation available for device testing; portrait Phase 5
is deferred until landscape approval.
Date: 2026-10-20
Target branch: `feature/ui-update-one`

Current rail revision: four fixed items, top to bottom: Photos (unavailable),
Settings, Zoom, Focus. Settings is no longer over the preview. The combined
Lock entry is temporarily hidden; its capture-service implementation is
retained. The rail is centered in the fitted preview's right pillarbox when
its full width plus 6-point clearance on each side fits. Otherwise it falls
back to the safe trailing edge, overlapping the image rather than cropping
the preview or shrinking touch targets. Vertical bounds respect the top and
bottom safe insets; the rail's end spacers keep its items away from corners.

## Implementation progress

- Pre-merge cleanup: remove the remaining portrait zoom preset row/menu and
  its UI-only configuration. Both orientations now use continuous sliders.
  Existing capture-service lens metadata and zoom policy tests are retained.
  Latest device-tuning overrides: landscape Zoom and EV sliders start hidden;
  Reset and AE entries in the exposure view are temporarily commented out.

- Landscape EV revision: the quick-strip EV button toggles horizontal inline
  exposure controls immediately above the strip (visible initially), instead
  of opening a modal panel. Reuse the compact EV readout/slider, Reset, and
  independent AE toggle; retain device bounds and recording-time adjustment.
  Settings and portrait exposure remain unchanged.

- Landscape zoom revision: replace the adjacent preset scale with a native
  vertical slider in the same bounds, with an upright current-zoom readout.
  Zoom toggles its visibility (visible initially) instead of opening a panel.
  Up increases zoom; supported bounds, the 8x cap, no-scroll behavior, and
  recording-time adjustment remain unchanged. Portrait zoom is unchanged.

- Phases 1-3: landscape chrome, symbol catalog, real format/EV/zoom controls,
  combined lock, monotonic recording timer, and unavailable future affordances
  implemented.
- Phase 4: simulator/device-target builds and focused policy/regression tests
  pass. Hosted landscape render checks cover standard and accessibility text
  sizes. Concurrency/accessibility review findings have been addressed.
- User hardware approval is still required: live-camera control responses,
  combined-lock behavior, HDMI audio/video, recording, safe-area placement,
  and the acceptance checklist below are not verified by a simulator render.
- Phase 5: not started. Existing portrait composition remains in place.
- Screenshot-driven landscape refinement: compact 64-point tool rail, single
  translucent format strip, smaller Record and Settings controls, and a visible
  device-supported magnification scale. Controls anchor to the fitted image
  and safe bounds without resizing the preview. Controls never scroll:
  narrow/large-text strips use labeled-accessibility icon buttons, zoom presets
  move into a native menu when needed, and the scale uses fixed zoom-step
  buttons when its preset ticks cannot fit. Unavailable features remain in
  Settings when omitted from the compact strip.
  Visual acceptance on the phone remains pending.
- Landscape quick controls anchor directly to the screen's safe bottom edge,
  without the image-control inset; the 44-point strip stays above the home
  indicator and centered below the image controls.
- Landscape chrome measures the full container before applying safe-area
  insets once. The rail uses the actual right pillarbox where it fits, with
  safe-trailing placement as a fallback. The zoom scale is positioned
  immediately beside the calculated rail, without device-specific offsets.

The combined lock tracks explicit user intent as well as confirmed device
modes. One-shot tap focus/metering can settle into locked device modes without
engaging the combined Lock button; this must not disable subsequent point taps.

## Purpose and references

Rework the landscape phone interface to follow the supplied CamVue mockup,
reusing working camera controls and reserving honest, disabled affordances for
future features. Yellow `<BUTTON>` annotations mean tap-to-cycle controls;
they are not part of the finished UI.

This plan extends [the camera-controls plan](camera-controls-plan.md).
Its historical baseline does not describe the current implementation: format,
zoom, focus, exposure, and assembled camera chrome already exist.

For this landscape redesign, the approved translucent preview overlays
supersede the earlier D7 preference for controls confined to black bars.
The full camera image must remain aspect-fit and uncropped underneath them.
Some image areas will be obscured by phone controls, as shown in the mockup.

## Approved decisions

| Area | Requirement |
| --- | --- |
| Resolution | One button cycles HD / 4K. Do not add an independent 1080 button. |
| Frame rate | One button cycles 24p / 30p. No 60p. |
| Exposure readout | Replace the mock aperture value with actual signed EV, such as EV +0.0. |
| Aperture | Deferred to a later version; no aperture adjustment in this pass. |
| Zoom | Display magnification, such as 0.5x, 1x, and 2x, not millimeters. |
| Zoom ceiling | Maximum displayed zoom is 8x, or the device's lower supported maximum. |
| Lock | One button locks focus and exposure together; tapping again restores continuous AF and AE. |
| Appearance | SF Symbols, translucent backgrounds, no added UI animations or animated panel transitions. |
| Symbol maintenance | Centralize camera-chrome SF Symbol names in a dedicated source file. |
| Portrait | Retain the existing composition through landscape approval; rework it afterward in separate Phase 5. |
| Future features | Clearly unavailable, disabled controls; no fake values or functionality. |

## Landscape composition

Use the mockup as a proportional reference, not fixed screen coordinates.
Adapt to device size, safe areas, and accessibility text sizes.

### Right tool rail

Dark/translucent rail with labeled SF Symbol controls:

- Photos: disabled future affordance, without a fabricated thumbnail.
- Lock: working combined focus/exposure lock with confirmed device state.
- Zoom: reveal/hide the working zoom adjustment surface.
- Focus: expose the existing AF/focus-lock control, synchronized with combined
  lock state. A frozen focus position is not a manual focus-distance slider.

Zoom and Focus presentation details should be kept simple and verified during
layout review. Do not invent additional camera modes.

### Preview overlays

- Upper-left Settings control: presents existing working camera settings using
  native Form/Section controls; do not imply unimplemented settings exist.
- Top-center recording indicator and real elapsed timer.
- Large Record/Stop control near the lower-right preview edge.
- Right-edge zoom adjustment/readout using supported magnification values.
- Brief focus/exposure tap reticle, not persistent face detection or tracking.
- Left-side reserved microphone-source and meter area.

The no-animation direction applies to the reworked landscape chrome, including
new panels and reticle transitions. Real timer/readout changes and eventual
audio measurements are live data, not decorative animation.

### Bottom quick-control strip

- Resolution: HD / 4K.
- Frame rate: 24p / 30p.
- EV: actual signed exposure bias; opens the existing adjustment and Reset
  controls rather than cycling an arbitrary subset of EV values.
- ISO and shutter: disabled future slots with unavailable labels.

Do not display the mock's f/5.6 or ISO 100 as measured values. Active labels
must reflect applied device state, including format fallback.

## Interaction and device-state rules

### Combined focus/exposure lock

1. From unlocked state, tapping Lock requests both focus and exposure to lock
   at their current values.
2. Tapping again restores continuous autofocus and continuous auto-exposure.
3. Show a closed lock only when both device modes confirm locked.
4. Mixed states must not appear fully locked. From a mixed state, Lock requests
   both locked; an independent focus unlock clears the combined indication.
5. While both are locked, preview taps must not request refocusing or metering,
   including VoiceOver's equivalent point actions. Do not show misleading
   tap-success feedback for blocked requests.
6. Zoom and EV adjustment remain available while locked and during recording.
7. If a requested mode is unsupported or fails, report it explicitly, read back
   actual device state, and do not claim that both locks succeeded.
8. This is separate from the automatic recording-orientation lock.

### Zoom

- Derive minimum, maximum, and presets from actual device capabilities.
- Do not offer 0.5x on unsupported hardware.
- Apply the 8x ceiling in displayed zoom space, accounting for the existing
  device/display zoom conversion.
- Enforce the same bounds in presets, adjustment controls, and service-level
  direct/ramped zoom requests. Preserve portrait composition but share these
  zoom limits across both orientations.
- Do not add a pinch gesture solely for this redesign; if any zoom input exists,
  it must respect the same bounds.

### Recording and format

- Keep the tested phone scene-specific orientation lock across startup,
  recording, and stopping.
- Block duplicate requests while recording transitions are in progress.
- Keep resolution/frame-rate changes unavailable throughout that lifecycle.
- Keep zoom, focus, combined lock, and EV accessible during recording.
- Start elapsed time from confirmed recording start, not the button tap.
- Display elapsed duration using an appropriate monotonic time reference;
  stop/reset consistently on completion or failure.
- Settings and format labels must not introduce a second conflicting source
  of capture state.

### HDMI invariants

- Fixed horizontal, clean 1920x1080 external output.
- Independent of phone orientation and selected recording resolution.
- No phone controls, placeholders, focus reticles, or timers in the HDMI feed.
- No changes to HDMI frame delivery or audio routing for this UI rework.

## Future-feature affordances

| Feature | This pass | Later activation |
| --- | --- | --- |
| Microphone source | Disabled, labeled unavailable | Real available-input selection in audio Phase 7 |
| Audio meters | Reserved unavailable state; no green sample bars | Actual capture-derived levels after audio refactor |
| Photos | Disabled icon/label; no fake thumbnail | Real library access and browsing |
| ISO | Disabled unavailable slot | Real manual exposure implementation |
| Shutter | Disabled unavailable slot | Real manual exposure implementation |
| Aperture | No adjustable control | Separate hardware-capability investigation |

Saving a recording to Photos already works; that does not mean library
browsing or thumbnail permissions are implemented.

## Implementation phases

### 1. Layout and shared symbols

- Refactor [CameraScreen](CineVideoApp/CineVideoApp/CameraScreen.swift) and
  [CameraLayout](CineVideoApp/CineVideoApp/CameraLayout.swift) for landscape rail,
  overlays, and quick strip without changing portrait composition.
- Add a small `CameraSymbols.swift` catalog of descriptive SF Symbol names.
  Adopt it across the camera chrome without building an unnecessary icon
  framework.
- Reuse [Theme](CineVideoApp/CineVideoApp/Theme.swift) and existing panel helpers
  where suitable; remove animations from the reworked landscape presentation.
- Keep the preview aspect-fit; do not crop it to accommodate controls.

### 2. Real controls and lifecycle

- Wire resolution/frame-rate cycling to existing format APIs.
- Wire EV and zoom surfaces to real state and adjustment APIs.
- Apply the shared 8x zoom cap using existing policy/conversion helpers.
- Implement the combined lock command on the session queue and publish
  device-confirmed state; gate both touch and accessible point actions.
- Add the real recording indicator and elapsed timer.
- Keep UI state on the main actor and AVFoundation mutations serialized on
  the existing session queue.

### 3. Honest future affordances

- Add only disabled, clearly named unavailable controls for deferred features.
- Do not introduce mock services, invented levels, static measured-looking
  values, fake thumbnails, or tappable no-ops.
- Preserve space for Phase 7 without implementing audio changes here.

### 4. Review and verification

- SwiftUI/accessibility review for labels, states, focus, reading order,
  minimum 44-point hit targets, large text, and contrast over live imagery.
- Concurrency review for combined device mutation and timer lifecycle.
- Focused regression tests for zoom limits/conversions, format cycling,
  mixed/unsupported lock states, blocked point actions, and recording timer
  start/finish/failure behavior.
- Build simulator and physical-iOS targets with existing tooling.
- Update directly related README documentation.
- User device approval before treating landscape behavior as complete.

### 5. Portrait adaptation (after landscape approval)

Implement only after Phases 1-4 are complete and the user approves the
landscape layout on device. Reflow the same controls rather than rotating or
shrinking the landscape interface.

- Top row: Settings on the left, recording status/timer in the center, and
  disabled Photos on the right, clear of the notch/Dynamic Island.
- Preview: retain the full aspect-fit image and existing point actions.
  Combined focus/exposure lock blocks touch and VoiceOver point actions.
  Use translucent overlays only where needed; do not crop the image or
  assume the black bars can accommodate every control.
- Zoom: horizontal supported-preset row above the capture controls, showing
  current magnification. Provide access to a horizontal continuous slider,
  with the same device-derived minimum and maximum capped at 8x.
- Capture row: large centered Record/Stop button, Focus on the left, combined
  Lock on the right. Keep positions stable during recording transitions.
- Bottom strip: HD/4K, 24p/30p, and signed EV in the same order as landscape.
  Put disabled ISO/Shutter slots in a secondary row where needed. Allow
  reflow or secondary-option panels at large text sizes rather than shrinking
  hit targets.
- Audio: compact disabled microphone/audio affordance for now. When audio
  Phase 7 supplies real measurements, use a horizontal meter rather than
  duplicating landscape's tall meter. No simulated levels.
- Reuse shared camera state, symbols, zoom policy, timer, confirmed lock
  behavior, and unavailable states. Only composition differs.
- Apply the same no-animation direction to the redesigned portrait chrome.
- Preserve recording-time orientation locking: do not switch compositions
  during a take. After recording, normal supported rotation resumes.
- Review accessibility and validate both orientations again. HDMI remains
  horizontal, clean, and fixed at 1080p throughout.

Portrait acceptance checks:

- [ ] Controls fit above the home indicator and below the notch without clipping.
- [ ] Preview remains uncropped at HD/4K, including with panels open.
- [ ] Zoom, format, EV, Focus, and combined Lock behave identically to landscape.
- [ ] Record/Stop placement stays stable across startup, recording, and stopping.
- [ ] Large text uses fixed alternate layouts without scrolling controls,
  overlapping controls, or reducing hit targets.
- [ ] VoiceOver order and panel focus follow the portrait arrangement.
- [ ] Idle rotation preserves settings and confirmed device state between layouts.
- [ ] Portrait recording stays portrait; HDMI stays horizontal and UI-free.
- [ ] No fake future-feature readings or decorative UI animations appear.

## On-device acceptance checklist

- [ ] Landscape Right layout follows the mockup without safe-area clipping.
- [ ] No extra orientations are enabled; existing Portrait + Landscape Right
      support remains unchanged.
- [ ] Preview remains uncropped at HD and 4K; overlays do not enter HDMI.
- [ ] Resolution and frame-rate buttons cycle correctly and show applied state.
- [ ] Format changes are blocked during startup, recording, and stopping.
- [ ] Zoom presets/range reflect hardware; all inputs stop at 8x or lower.
- [ ] Combined Lock freezes focus and exposure; a second tap restores both.
- [ ] Mixed focus/exposure states never display a confirmed combined lock.
- [ ] Locked preview taps and VoiceOver point actions do not change AF/AE.
- [ ] Zoom and EV remain usable while combined lock is active.
- [ ] Recording indicator/timer follow actual capture and recover from failure.
- [ ] Landscape recording does not snap to portrait or resize unexpectedly.
- [ ] Stopping recording restores normal phone rotation.
- [ ] HDMI remains clean, horizontal, and 1080p with phone portrait/landscape.
- [ ] HDMI connection/disconnection during a take does not disturb the phone lock.
- [ ] Portrait layout remains functional with the shared zoom/lock behavior.
- [ ] Future controls are clearly unavailable and cannot be activated.
- [ ] No decorative animations in the redesigned landscape interface.
- [ ] VoiceOver, large text, and bright-scene contrast remain usable.
- [ ] Saved clips retain correct framing, orientation, and audio.

## Out of scope

External-audio backend work, Photos browsing, manual ISO/shutter/aperture,
face/subject tracking, and new supported orientations require separate
implementation approval. Portrait redesign is approved as Phase 5, not part
of the initial landscape delivery.
