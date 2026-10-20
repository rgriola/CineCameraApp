import Testing
import UIKit
@testable import CineVideoApp

@MainActor
struct OrientationLockTests {
    @Test("A landscape recording keeps the phone landscape")
    func landscapeMask() throws {
        #expect(try OrientationLock.mask(for: .landscapeRight) == .landscapeRight)
    }

    @Test("A portrait recording keeps the phone portrait")
    func portraitMask() throws {
        #expect(try OrientationLock.mask(for: .portrait) == .portrait)
    }

    @Test("Unknown and unsupported orientations never silently become portrait",
          arguments: [UIInterfaceOrientation.unknown, .landscapeLeft, .portraitUpsideDown])
    func rejectsInvalidOrientation(_ orientation: UIInterfaceOrientation) {
        #expect(throws: OrientationLock.LockError.self) {
            try OrientationLock.mask(for: orientation)
        }
    }

    @Test("HDMI stays landscape regardless of phone lock or query order",
          arguments: [false, true])
    func independentExternalPolicy(externalFirst: Bool) {
        let roles: [UISceneSession.Role] = externalFirst
            ? [.windowExternalDisplayNonInteractive, .windowApplication]
            : [.windowApplication, .windowExternalDisplayNonInteractive]
        for role in roles {
            let mask = OrientationLock.supportedMask(for: role, phoneLock: .portrait)
            #expect(mask == (role == .windowApplication ? .portrait : .landscapeRight))
        }
        #expect(OrientationLock.supportedMask(for: .windowExternalDisplayNonInteractive, phoneLock: nil) == .landscapeRight)
    }

    @Test("Unlocked phone supports portrait and landscape right")
    func idlePhonePolicy() {
        #expect(OrientationLock.supportedMask(for: .windowApplication, phoneLock: nil) == [.portrait, .landscapeRight])
    }

    @Test("A missing preview scene rejects recording instead of searching other scenes")
    func missingScene() {
        #expect(throws: OrientationLock.LockError.self) {
            try OrientationLock.lock(in: nil)
        }
    }

    @Test("Recording is rejected explicitly when its camera view has no window")
    func managerRejectsMissingScene() {
        let manager = CameraManager()
        manager.isSessionRunning = true
        let preview = UIView()
        manager.cameraPreviewView = preview
        manager.toggleRecording()
        #expect(manager.recordingPhase == .idle)
        #expect(!manager.isOrientationLocked)
        #expect(manager.lastError != nil)
    }

    @Test("Recording is rejected explicitly when the session isn't ready")
    func managerRejectsUnavailableSession() {
        let manager = CameraManager()
        manager.toggleRecording()
        #expect(manager.recordingPhase == .idle)
        #expect(!manager.isOrientationLocked)
        #expect(manager.lastError != nil)
    }

    @Test("Start, record, and stop all retain the orientation lock until completion")
    func lifecycle() {
        var phase = RecordingPhase.idle
        #expect(!phase.locksOrientation)
        let began = phase.begin()
        #expect(began)
        #expect(phase.locksOrientation)
        #expect(phase.isTransitioning)
        let duplicateStart = phase.begin()
        let prematureStop = phase.stop()
        let started = phase.didStart()
        #expect(!duplicateStart)
        #expect(!prematureStop)
        #expect(started)
        #expect(phase.locksOrientation)
        #expect(!phase.isTransitioning)
        let startWhileRecording = phase.begin()
        let stopped = phase.stop()
        #expect(!startWhileRecording)
        #expect(stopped)
        #expect(phase.locksOrientation)
        #expect(phase.isTransitioning)
        let duplicateStop = phase.stop()
        let startWhileStopping = phase.begin()
        #expect(!duplicateStop)
        #expect(!startWhileStopping)
        phase.finish()
        #expect(!phase.locksOrientation)
        #expect(!phase.isTransitioning)
        let restarted = phase.begin()
        #expect(restarted)
    }

    @Test("Startup failure and recording failure both return to idle",
          arguments: [false, true])
    func failureCleanup(afterStart: Bool) {
        var phase = RecordingPhase.idle
        let began = phase.begin()
        #expect(began)
        if afterStart {
            let started = phase.didStart()
            #expect(started)
        }
        phase.finish()
        #expect(phase == .idle)
        #expect(!phase.locksOrientation)
        let restarted = phase.begin()
        #expect(restarted)
    }
}
