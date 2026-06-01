/// AudioCaptureEngine — routes an aggregate-device input into a live RMS
/// callback using AVAudioEngine's installTap API.

import AVFoundation
import CoreAudio
import Foundation

// ── Errors ────────────────────────────────────────────────────────────────────

enum CaptureEngineError: LocalizedError {
    case inputNodeHasNoAudioUnit
    case deviceSetFailed(OSStatus)
    case engineStartFailed(Error)

    var errorDescription: String? {
        switch self {
        case .inputNodeHasNoAudioUnit:
            return "AVAudioEngine inputNode.audioUnit is nil (engine not yet initialised)"
        case .deviceSetFailed(let s):
            return "kAudioOutputUnitProperty_CurrentDevice set failed (OSStatus \(s))"
        case .engineStartFailed(let e):
            return "AVAudioEngine.start() threw: \(e.localizedDescription)"
        }
    }
}

// ── AudioCaptureEngine ────────────────────────────────────────────────────────

final class AudioCaptureEngine {

    private let engine = AVAudioEngine()
    private(set) var isRunning = false

    /// `onRMS` is called from the AVAudio realtime thread — dispatch to main
    /// before touching any UI.
    var onRMS: ((_ left: Float, _ right: Float) -> Void)?

    // MARK: - Setup

    /// Point AVAudioEngine's input node at `aggDeviceID` and install a tap
    /// that reports per-frame RMS to `onRMS`.
    func configure(aggDeviceID: AudioDeviceID, sampleRate: Double) throws {
        let inputNode = engine.inputNode

        // ── 1. Redirect the HAL Output AudioUnit to our aggregate device ──
        guard let auHAL = inputNode.audioUnit else {
            throw CaptureEngineError.inputNodeHasNoAudioUnit
        }
        var devID = aggDeviceID
        let setStatus = AudioUnitSetProperty(
            auHAL,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard setStatus == noErr else { throw CaptureEngineError.deviceSetFailed(setStatus) }

        // ── 2. Use a known-good format (stereo float32 @ tap sample rate) ─
        // We specify the format explicitly to avoid format mismatch errors.
        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 2
        )!

        // ── 3. Install tap on bus 0 ───────────────────────────────────────
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.processTapBuffer(buffer)
        }
    }

    // MARK: - Start / Stop

    func start() throws {
        guard !isRunning else { return }
        do {
            try engine.start()
            isRunning = true
        } catch {
            throw CaptureEngineError.engineStartFailed(error)
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    // MARK: - Buffer Processing

    /// Calculate per-channel RMS and forward to `onRMS`.
    private func processTapBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        func rms(_ ptr: UnsafePointer<Float>, count: Int) -> Float {
            var sum: Float = 0
            for i in 0..<count { sum += ptr[i] * ptr[i] }
            return sqrt(sum / Float(count))
        }

        let left  = rms(channelData[0], count: frameCount)
        let right = buffer.format.channelCount > 1
            ? rms(channelData[1], count: frameCount)
            : left

        onRMS?(left, right)
    }

    deinit { stop() }
}
