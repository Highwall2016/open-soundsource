/// AggregateDeviceManager — creates a private CoreAudio Aggregate Device
/// that wraps a process tap, making the tap's audio stream available as
/// a regular input device to AVAudioEngine.
///
/// The aggregate device is private (invisible in Audio MIDI Setup) and
/// lives only as long as this object is alive.

import CoreAudio
import Foundation

// ── Errors ────────────────────────────────────────────────────────────────────

enum AggregateDeviceError: LocalizedError {
    case createFailed(OSStatus)
    case destroyFailed(OSStatus)
    case sampleRateQueryFailed

    var errorDescription: String? {
        switch self {
        case .createFailed(let s):   return "AudioHardwareCreateAggregateDevice failed (OSStatus \(s))"
        case .destroyFailed(let s):  return "AudioHardwareDestroyAggregateDevice failed (OSStatus \(s))"
        case .sampleRateQueryFailed: return "Could not query aggregate device sample rate"
        }
    }
}

// ── AggregateDeviceManager ───────────────────────────────────────────────────

final class AggregateDeviceManager {

    private(set) var deviceID: AudioDeviceID = kAudioObjectUnknown

    // MARK: - Create

    /// Build an aggregate device that contains the process tap identified by `tapUID`.
    ///
    /// The tap UID comes from `ProcessTapManager.tapUID(for:)`.
    /// Returns the new aggregate device's `AudioDeviceID`.
    @discardableResult
    func createDevice(tapUID: String) throws -> AudioDeviceID {
        // Each aggregate device needs a unique UID to avoid conflicts
        // across multiple runs of the tool.
        let aggUID = "com.oss-poc.aggregate.\(UUID().uuidString)"

        // Sub-tap dictionary: which tap to include, and whether to apply
        // drift compensation (false for minimum latency in a PoC).
        let subTapDict: [String: Any] = [
            kAudioSubTapUIDKey as String:              tapUID,
            kAudioSubTapDriftCompensationKey as String: false,
        ]

        // Aggregate device description dictionary.
        // kAudioAggregateDeviceIsPrivateKey = 1 keeps it out of the
        // system UI (Audio MIDI Setup, Sound prefs).
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String:      "OSS-PoC Tap Aggregate",
            kAudioAggregateDeviceUIDKey  as String:      aggUID,
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceTapListKey as String:   [subTapDict],
        ]

        var newDeviceID = AudioDeviceID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &newDeviceID)
        guard status == noErr else { throw AggregateDeviceError.createFailed(status) }

        deviceID = newDeviceID
        return newDeviceID
    }

    // MARK: - Sample Rate

    /// Query the nominal sample rate of the aggregate device.
    func sampleRate(for devID: AudioDeviceID) throws -> Double {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(devID, &addr, 0, nil, &size, &rate)
        guard status == noErr, rate > 0 else { throw AggregateDeviceError.sampleRateQueryFailed }
        return rate
    }

    // MARK: - Destroy

    func destroyDevice() {
        guard deviceID != kAudioObjectUnknown else { return }
        let status = AudioHardwareDestroyAggregateDevice(deviceID)
        if status != noErr {
            fputs("⚠️  destroyAggregateDevice: OSStatus \(status)\n", stderr)
        }
        deviceID = kAudioObjectUnknown
    }

    deinit { destroyDevice() }
}
