#!/usr/bin/env swift
/// Test: compare using tapUUID.uuidString vs actual kAudioTapPropertyUID
/// for kAudioSubTapUIDKey in the aggregate device.
/// This reveals whether a UID mismatch causes the silent-capture bug.

import CoreAudio
import AVFoundation
import AppKit
import Foundation

func *(lhs: String, rhs: Int) -> String { String(repeating: lhs, count: rhs) }

let system = AudioObjectID(kAudioObjectSystemObject)

guard let braveApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.brave.Browser" }) else {
    print("Brave not running"); exit(1)
}
let bundleID = braveApp.bundleIdentifier!

// Find process objects (same logic as app)
func getProcessObjectIDs() -> [AudioObjectID] {
    let prefix = bundleID + "."
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids)

    var matched: [AudioObjectID] = []
    for id in ids {
        var bidAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
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

func testWithUID(label: String, useActualUID: Bool) -> Float {
    print("\n" + "=" * 50)
    print("TEST: \(label)")
    print("=" * 50)

    let tapUUID = UUID()
    let desc = CATapDescription(stereoMixdownOfProcesses: processObjIDs)
    desc.uuid = tapUUID
    desc.isPrivate = false
    desc.muteBehavior = .muted

    var tapID = AudioObjectID(kAudioObjectUnknown)
    guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr else { print("Tap failed"); return -1 }

    // Get the UID to use
    let tapUIDForAggregate: String
    if useActualUID {
        var tapUIDAddr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var tapUIDVal: Unmanaged<CFString>? = nil
        var tapUIDSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(tapID, &tapUIDAddr, 0, nil, &tapUIDSize, &tapUIDVal) == noErr,
           let uid = tapUIDVal?.takeRetainedValue() as String? {
            tapUIDForAggregate = uid
        } else {
            tapUIDForAggregate = tapUUID.uuidString
        }
    } else {
        tapUIDForAggregate = tapUUID.uuidString
    }

    print("  tapUUID.uuidString: \(tapUUID.uuidString)")
    print("  UID used for aggregate: \(tapUIDForAggregate)")
    print("  Match: \(tapUUID.uuidString == tapUIDForAggregate)")

    let aggDesc: [String: Any] = [
        kAudioAggregateDeviceNameKey: "OSS_UIDTest",
        kAudioAggregateDeviceUIDKey: UUID().uuidString,
        kAudioAggregateDeviceIsPrivateKey: 1,
        kAudioAggregateDeviceTapListKey: [[
            kAudioSubTapUIDKey: tapUIDForAggregate,
            kAudioSubTapDriftCompensationKey: false
        ]]
    ]
    var aggDeviceID = AudioDeviceID(kAudioObjectUnknown)
    guard AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggDeviceID) == noErr else {
        AudioHardwareDestroyProcessTap(tapID); print("Aggregate failed"); return -1
    }

    var srAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var deviceSR: Float64 = 0
    var srSize = UInt32(MemoryLayout<Float64>.size)
    AudioObjectGetPropertyData(aggDeviceID, &srAddr, 0, nil, &srSize, &deviceSR)
    if deviceSR <= 0 { deviceSR = 48000 }

    Thread.sleep(forTimeInterval: 0.5)

    // AUHAL setup (matching app code exactly)
    var captureDesc = AudioComponentDescription(
        componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
    )
    let component = AudioComponentFindNext(nil, &captureDesc)!
    var optCU: AudioUnit?
    AudioComponentInstanceNew(component, &optCU)
    let captureUnit = optCU!

    var one: UInt32 = 1; var zero: UInt32 = 0
    AudioUnitSetProperty(captureUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, UInt32(MemoryLayout<UInt32>.size))
    AudioUnitSetProperty(captureUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, UInt32(MemoryLayout<UInt32>.size))

    var devID = aggDeviceID
    AudioUnitSetProperty(captureUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &devID, UInt32(MemoryLayout<AudioDeviceID>.size))

    // Use device sample rate (the fix)
    let captureFormat = AVAudioFormat(standardFormatWithSampleRate: deviceSR, channels: 2)!
    var outASBD = captureFormat.streamDescription.pointee
    AudioUnitSetProperty(captureUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &outASBD, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

    class Ctx {
        let captureUnit: AudioUnit
        let format: AVAudioFormat
        var bufCount: UInt64 = 0; var okCount: UInt64 = 0; var errCount: UInt64 = 0
        var lastErr: OSStatus = 0; var peak: Float = 0
        init(_ cu: AudioUnit, _ f: AVAudioFormat) { captureUnit = cu; format = f }
    }
    let ctx = Ctx(captureUnit, captureFormat)
    let ctxRetained = Unmanaged.passRetained(ctx)

    var cb = AURenderCallbackStruct(
        inputProc: { (inRefCon, ioActionFlags, inTimeStamp, _, inNumberFrames, _) -> OSStatus in
            let c = Unmanaged<Ctx>.fromOpaque(inRefCon).takeUnretainedValue()
            c.bufCount += 1
            guard let buffer = AVAudioPCMBuffer(pcmFormat: c.format, frameCapacity: inNumberFrames) else { return noErr }
            buffer.frameLength = inNumberFrames
            let st = withUnsafeMutablePointer(to: &buffer.mutableAudioBufferList.pointee) { ablPtr in
                AudioUnitRender(c.captureUnit, ioActionFlags, inTimeStamp, 1, inNumberFrames, ablPtr)
            }
            if st != noErr { c.errCount += 1; c.lastErr = st; return noErr }
            c.okCount += 1
            if let cd = buffer.floatChannelData {
                for i in 0..<Int(buffer.frameLength) {
                    let s = abs(cd[0][i]); if s > c.peak { c.peak = s }
                }
            }
            return noErr
        },
        inputProcRefCon: ctxRetained.toOpaque()
    )

    AudioUnitSetProperty(captureUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
    AudioUnitInitialize(captureUnit)
    AudioOutputUnitStart(captureUnit)

    Thread.sleep(forTimeInterval: 3.0)

    let peak = ctx.peak
    let ok = ctx.okCount; let err = ctx.errCount
    let peakDB = peak > 0 ? String(format: "%.1f", 20.0 * log10(Double(peak))) : "-inf"
    print("  Result: ok=\(ok) err=\(err) peak=\(String(format: "%.6f", peak)) (\(peakDB)dB)")
    print("  \(peak > 0.001 ? "✓ HAS AUDIO" : "✗ SILENT")")

    AudioOutputUnitStop(captureUnit)
    AudioUnitUninitialize(captureUnit)
    AudioComponentInstanceDispose(captureUnit)
    ctxRetained.release()
    AudioHardwareDestroyAggregateDevice(aggDeviceID)
    AudioHardwareDestroyProcessTap(tapID)

    return peak
}

print("Make sure Brave is playing audio!\n")

let peak1 = testWithUID(label: "Using tapUUID.uuidString (OLD app behavior)", useActualUID: false)
Thread.sleep(forTimeInterval: 0.5)
let peak2 = testWithUID(label: "Using actual kAudioTapPropertyUID (NEW fix)", useActualUID: true)

print("\n" + "=" * 50)
print("COMPARISON")
print("=" * 50)
print("  OLD (tapUUID.uuidString): peak=\(String(format: "%.6f", peak1)) → \(peak1 > 0.001 ? "AUDIO" : "SILENT")")
print("  NEW (actual tap UID):     peak=\(String(format: "%.6f", peak2)) → \(peak2 > 0.001 ? "AUDIO" : "SILENT")")

if peak1 < 0.001 && peak2 > 0.001 {
    print("\n🎯 CONFIRMED: Using tapUUID.uuidString causes silence!")
    print("   The actual tap UID differs from the UUID set on CATapDescription.")
} else if peak1 > 0.001 && peak2 > 0.001 {
    print("\n✓ Both methods work — tap UID matches UUID (this run)")
    print("  The silent-capture bug may be intermittent or caused by something else")
} else if peak1 < 0.001 && peak2 < 0.001 {
    print("\n❌ Both are silent — Brave may not be producing audio")
} else {
    print("\n⚠️ Unexpected: OLD has audio but NEW doesn't")
}
