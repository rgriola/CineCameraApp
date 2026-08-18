//
//  AudioMirror.swift
//  CineVideoApp
//
//  Created by rgriola on 8/18/26.
//

import AVFoundation
import OSLog

/// Taps the capture session's live audio and plays it back immediately
/// through `AVAudioEngine`. `AVCaptureAudioPreviewOutput` — the obvious API
/// for this — is unavailable on iOS, so this is the standard substitute:
/// capture raw buffers via `AVCaptureAudioDataOutput`, then feed them
/// straight into an `AVAudioPlayerNode`. Whatever the system's current audio
/// output route is — including a connected HDMI/USB adapter — is where this
/// plays; no manual route targeting is needed or possible on iOS.
///
/// `AVAudioEngine`/`AVAudioPlayerNode` are MainActor-isolated types in this
/// SDK, so engine setup/playback is hopped to the main actor. Sample buffers
/// arrive on a background queue and are converted to `AVAudioPCMBuffer`
/// (plain CoreMedia/CoreAudio work, not actor-isolated) before that hop, so
/// the conversion itself never blocks the main thread.
final class AudioMirror: NSObject, @unchecked Sendable {
    private let audioOutput = AVCaptureAudioDataOutput()
    private let processingQueue = DispatchQueue(label: "com.cinevideoapp.audiomirror")

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var isEngineRunning = false
    private var connectedFormat: AVAudioFormat?

    /// Adds the audio tap to `session` and prepares for playback. Both
    /// `AVCaptureAudioDataOutput` and `AVAudioEngine` are MainActor-isolated
    /// types in this SDK, so this — like `ExternalDisplayController`, its
    /// only caller — runs on the main actor rather than the session queue.
    func start(on session: AVCaptureSession) {
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

    /// Removes the audio tap from `session` and tears down the engine.
    func stop(on session: AVCaptureSession) {
        session.beginConfiguration()
        session.removeOutput(audioOutput)
        session.commitConfiguration()
        teardownEngine()
        Logger.externalDisplay.notice("Audio mirror tap removed from session.")
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
        if isEngineRunning, connectedFormat == format { return }
        if isEngineRunning { teardownEngine() }

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
            playerNode.play()
            isEngineRunning = true
            connectedFormat = format
            Logger.externalDisplay.info("Audio mirror engine started.")
        } catch {
            Logger.externalDisplay.error("AudioMirror failed to start engine: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func play(_ pcmBuffer: AVAudioPCMBuffer, format: AVAudioFormat) {
        ensureEngineRunning(format: format)
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
