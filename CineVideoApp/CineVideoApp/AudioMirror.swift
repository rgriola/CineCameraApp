//
//  AudioMirror.swift
//  CineVideoApp
//
//  Created by rgriola on 8/18/26.
//

@preconcurrency import AVFoundation
import OSLog

/// Taps the capture session's live audio and plays it back immediately
/// through `AVAudioEngine`. `AVCaptureAudioPreviewOutput` — the obvious API
/// for this — is unavailable on iOS, so this is the standard substitute:
/// capture raw buffers via `AVCaptureAudioDataOutput`, then feed them
/// straight into an `AVAudioPlayerNode`. Whatever the system's current audio
/// output route is — including a connected HDMI/USB adapter — is where this
/// plays; no manual route targeting is needed or possible on iOS.
///
/// `start(on:)`/`stop(on:)` are `nonisolated` so `ExternalDisplayController`
/// can dispatch them onto `CameraManager`'s sessionQueue — every
/// `AVCaptureSession` mutation in this app funnels through that one queue,
/// since the session isn't safe for concurrent configuration from multiple
/// threads. `AVAudioEngine`/`AVAudioPlayerNode`, however, are MainActor-isolated
/// types in this SDK, so engine setup/playback/teardown always hops to main.
final class AudioMirror: NSObject, @unchecked Sendable {
    // `nonisolated(unsafe)` — touched only from sessionQueue (session add/
    // remove) or the capture delegate callback (itself off-main), never
    // concurrently, by convention — same pattern as `CameraSession`.
    nonisolated(unsafe) private let audioOutput = AVCaptureAudioDataOutput()
    private let processingQueue = DispatchQueue(label: "com.cinevideoapp.audiomirror")

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var isEngineRunning = false
    private var connectedFormat: AVAudioFormat?
    private var configurationChangeObserver: NSObjectProtocol?

    override init() {
        super.init()

        // The hardware graph AVAudioEngine built (sample rate, channel
        // layout, the physical output device) can become stale the instant
        // the active audio route changes — e.g. an HDMI adapter connecting
        // introduces a new output route. Continuing to drive a stale graph
        // is what throws the uncaught Objective-C exceptions that take the
        // whole app down, so any configuration change fully rebuilds it.
        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                Logger.externalDisplay.notice("AVAudioEngine configuration changed; rebuilding audio mirror graph.")
                self?.teardownEngine()
            }
        }
    }

    deinit {
        if let configurationChangeObserver {
            NotificationCenter.default.removeObserver(configurationChangeObserver)
        }
    }

    /// Adds the audio tap to `session`. Must be called on the session's own
    /// serial queue — see `CameraManager.withSessionQueue`.
    nonisolated func start(on session: AVCaptureSession) {
        guard session.canAddOutput(audioOutput) else {
            Logger.externalDisplay.warning("Cannot add audio mirror output to session.")
            return
        }
        audioOutput.setSampleBufferDelegate(self, queue: processingQueue)
        session.beginConfiguration()
        session.addOutput(audioOutput)
        session.commitConfiguration()
        Logger.externalDisplay.notice("Audio mirror tap added to session.")
    }

    /// Removes the audio tap from `session` and tears down the engine. Must
    /// be called on the session's own serial queue — see `CameraManager.withSessionQueue`.
    nonisolated func stop(on session: AVCaptureSession) {
        session.beginConfiguration()
        session.removeOutput(audioOutput)
        session.commitConfiguration()
        Logger.externalDisplay.notice("Audio mirror tap removed from session.")

        Task { @MainActor [self] in
            teardownEngine()
        }
    }

    private func teardownEngine() {
        guard isEngineRunning else { return }
        playerNode.stop()
        engine.stop()
        engine.disconnectNodeInput(playerNode)
        isEngineRunning = false
        connectedFormat = nil
    }

    private func ensureEngineRunning(format: AVAudioFormat) {
        guard format.sampleRate > 0, format.channelCount > 0 else {
            Logger.externalDisplay.error("Ignoring invalid audio format: sampleRate=\(format.sampleRate), channels=\(format.channelCount).")
            return
        }
        if isEngineRunning, connectedFormat == format { return }
        if isEngineRunning { teardownEngine() }

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
            playerNode.play()
            isEngineRunning = true
            connectedFormat = format
            Logger.externalDisplay.info("Audio mirror engine started: \(format.sampleRate, privacy: .public)Hz, \(format.channelCount, privacy: .public)ch.")
        } catch {
            Logger.externalDisplay.error("AudioMirror failed to start engine: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func play(_ pcmBuffer: AVAudioPCMBuffer, format: AVAudioFormat) {
        ensureEngineRunning(format: format)
        guard isEngineRunning else { return }
        playerNode.scheduleBuffer(pcmBuffer)
    }
}

extension AudioMirror: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        guard let pcmBuffer = Self.makePCMBuffer(from: sampleBuffer, format: format) else { return }

        Task { @MainActor [self] in
            play(pcmBuffer, format: format)
        }
    }

    nonisolated private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }
        pcmBuffer.frameLength = frameCount

        var audioBufferList = AudioBufferList()
        var blockBuffer: CMBlockBuffer?

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let source = UnsafeMutableAudioBufferListPointer(&audioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)
        for index in 0..<min(source.count, destination.count) {
            guard let sourceData = source[index].mData, let destinationData = destination[index].mData else { continue }
            memcpy(destinationData, sourceData, Int(source[index].mDataByteSize))
            destination[index].mDataByteSize = source[index].mDataByteSize
        }

        return pcmBuffer
    }
}
