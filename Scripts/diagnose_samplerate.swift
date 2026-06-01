#!/usr/bin/env swift
/// Quick test: does fixing the sample rate make AudioUnitRender succeed?
/// The AUHAL default output format is 44100Hz but the aggregate device runs at 48000Hz.

import CoreAudio
import AVFoundation
import AppKit
import Foundation

func *(lhs: String, rhs: Int) -> String { String(repeating: lhs, count: rhs) }

let system = AudioObjectID(kAudioObjectSystemObject)

// Find Brave
let runningApps = NSWorkspace.shared.runningApplications
guard let braveApp = runningApps.first(where: { $0.bundleIdentifier == "com.brave.Browser" }) else {
    print("Brave not running"); exit(1)
}
let pid = braveApp.processIdentifier
let bundleID = braveApp.bundleIdentifier!
print("Brave PID: \(pid)")

// Find process objects
func getProcessObjectIDs() -> [AudioObjectID] {
    let prefix = bundleID + "."
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids)

    var matched: [AudioObjectID] = []
    for id in ids {
        var bidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var bidVal: Unmanaged<CFString>? = nil
        var bidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(id, &bidAddr, 0, nil, &bidSize, &bidVal) == noErr {
            if let bid = bidVal?.takeRetainedValue() as String? {
                if bid == bundleID || bid.hasPrefix(prefix) { matched.append(id) }
            }
        }
    }
    return matched
}

let processObjIDs = getProcessObjectIDs()
guard !processObjIDs.isEmpty else { print("No process objects"); exit(1) }
print("Process objects: \(processObjIDs)")

// Create tap
let tapUUID = UUID()
let desc = CATapDescription(stereoMixdownOfProcesses: processObjIDs)
desc.uuid = tapUUID
desc.isPrivate = false
desc.muteBehavior = .unmuted

var tapID = AudioObjectID(kAudioObjectUnknown)
guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr else { print("Tap failed"); exit(1) }

// Create aggregate
let aggDesc: [String: Any] = [
    kAudioAggregateDeviceNameKey: "OSS_Diag2",
    kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceIsPrivateKey: 1,
    kAudioAggregateDeviceTapListKey: [[
        kAudioSubTapUIDKey: tapUUID.uuidString,
        kAudioSubTapDriftCompensationKey: false
    ]]
]

var aggDeviceID = AudioDeviceID(kAudioObjectUnknown)
guard AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggDeviceID) == noErr else {
    print("Aggregate failed"); AudioHardwareDestroyProcessTap(tapID); exit(1)
}

// Query ACTUAL device sample rate
var srAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var deviceSR: Float64 = 0
var srSize = UInt32(MemoryLayout<Float64>.size)
AudioObjectGetPropertyData(aggDeviceID, &srAddr, 0, nil, &srSize, &deviceSR)
print("Aggregate device sample rate: \(Int(deviceSR)) Hz")

Thread.sleep(forTimeInterval: 0.5)

// Create AUHAL
var captureDesc = AudioComponentDescription(
    componentType: kAudioUnitType_Output,
    componentSubType: kAudioUnitSubType_HALOutput,
    componentManufacturer: kAudioUnitManufacturer_Apple,
    componentFlags: 0, componentFlagsMask: 0
)
let component = AudioComponentFindNext(nil, &captureDesc)!
var optCU: AudioUnit?
AudioComponentInstanceNew(component, &optCU)
let captureUnit = optCU!

var one: UInt32 = 1
var zero: UInt32 = 0
AudioUnitSetProperty(captureUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, UInt32(MemoryLayout<UInt32>.size))
AudioUnitSetProperty(captureUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, UInt32(MemoryLayout<UInt32>.size))

var devID = aggDeviceID
AudioUnitSetProperty(captureUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &devID, UInt32(MemoryLayout<AudioDeviceID>.size))

// Query AUHAL's default output scope bus 1 format (this is what the app uses)
var defaultASBD = AudioStreamBasicDescription()
var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
AudioUnitGetProperty(captureUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &defaultASBD, &asbdSize)
print("\nAUHAL default output format (bus 1): \(defaultASBD.mChannelsPerFrame)ch, \(Int(defaultASBD.mSampleRate))Hz")
print("  ← THIS IS THE BUG: \(Int(defaultASBD.mSampleRate))Hz vs device \(Int(deviceSR))Hz")

// Also query input scope bus 1 (hardware side)
var inputASBD = AudioStreamBasicDescription()
AudioUnitGetProperty(captureUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &inputASBD, &asbdSize)
print("AUHAL input format (bus 1, hw side): \(inputASBD.mChannelsPerFrame)ch, \(Int(inputASBD.mSampleRate))Hz")

// FIX: Use device's actual sample rate for the output format
print("\n--- Testing with FIXED sample rate (\(Int(deviceSR))Hz) ---")
let channels = defaultASBD.mChannelsPerFrame > 0 ? defaultASBD.mChannelsPerFrame : 2
let fixedFormat = AVAudioFormat(standardFormatWithSampleRate: deviceSR, channels: AVAudioChannelCount(channels))!
var fixedASBD = fixedFormat.streamDescription.pointee
let setStatus = AudioUnitSetProperty(captureUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fixedASBD, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
print("Set output format to \(Int(deviceSR))Hz: OSStatus \(setStatus)")

AudioUnitInitialize(captureUnit)
AudioOutputUnitStart(captureUnit)

// Try rendering manually
Thread.sleep(forTimeInterval: 0.3)

var timestamp = AudioTimeStamp()
timestamp.mFlags = .sampleTimeValid
timestamp.mSampleTime = 0

let testBuffer = AVAudioPCMBuffer(pcmFormat: fixedFormat, frameCapacity: 512)!
testBuffer.frameLength = 512
var flags = AudioUnitRenderActionFlags()

var successCount = 0
var failCount = 0
var lastError: OSStatus = 0

for i in 0..<100 {
    timestamp.mSampleTime = Double(i * 512)
    testBuffer.frameLength = 512

    let renderStatus = withUnsafeMutablePointer(to: &testBuffer.mutableAudioBufferList.pointee) { ablPtr in
        AudioUnitRender(captureUnit, &flags, &timestamp, 1, 512, ablPtr)
    }
    if renderStatus == noErr {
        successCount += 1
        // Check audio level
        if let cd = testBuffer.floatChannelData {
            var peak: Float = 0
            for j in 0..<Int(testBuffer.frameLength) {
                let s = abs(cd[0][j])
                if s > peak { peak = s }
            }
            if i % 20 == 0 {
                print("  render[\(i)] OK peak=\(String(format: "%.4f", peak))")
            }
        }
    } else {
        failCount += 1
        lastError = renderStatus
    }
    Thread.sleep(forTimeInterval: 0.01)
}

print("\nResults: \(successCount) success, \(failCount) failed (last error: \(lastError))")
if successCount > 0 {
    print("✓ FIX CONFIRMED: Using device sample rate (\(Int(deviceSR))Hz) makes AudioUnitRender work!")
} else {
    print("❌ Still failing — the issue is not just sample rate")
}

// Cleanup
AudioOutputUnitStop(captureUnit)
AudioUnitUninitialize(captureUnit)
AudioComponentInstanceDispose(captureUnit)
AudioHardwareDestroyAggregateDevice(aggDeviceID)
AudioHardwareDestroyProcessTap(tapID)
print("Cleaned up")
