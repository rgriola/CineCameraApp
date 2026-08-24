//
//  RotationCorrectionTests.swift
//  CineVideoAppTests
//
//  Regression guard for the deliberate "no sensor-mount correction" decision
//  in `RotationCorrection.swift`. That identity mapping was verified end-to-end
//  on real hardware (Preview + Recording connections, Portrait and Landscape
//  Right, live while rotating) after earlier attempts at a fixed offset proved
//  wrong. If someone reintroduces an offset here, these tests should fail loudly
//  so the change is a conscious, re-verified decision rather than a silent
//  regression.
//

import Testing
import CoreGraphics
@testable import CineVideoApp

struct RotationCorrectionTests {

    /// `sensorMountCorrected` must return its input unchanged for every angle —
    /// including the four cardinal capture angles the app actually applies
    /// (0/90/180/270), plus a non-cardinal and out-of-range values to prove the
    /// mapping is a pure identity, not a lookup table with gaps.
    @Test("sensorMountCorrected is the identity mapping (no correction)",
          arguments: [0, 90, 180, 270, 45, 360, -90] as [CGFloat])
    func sensorMountCorrectionIsIdentity(_ angle: CGFloat) {
        #expect(angle.sensorMountCorrected == angle)
    }
}
