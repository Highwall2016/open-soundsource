#!/usr/bin/env swift
/// Investigate which Brave process objects actually produce audio.
/// Lists ALL audio process objects, identifies Brave-related ones,
/// and taps each individually to check which has audio.

import CoreAudio
import AVFoundation
import AppKit
import Foundation

let system = AudioObjectID(kAudioObjectSystemObject)

// MARK: - List ALL audio process objects with details
print("=" * 60)
print("Brave Audio Process Investigation")
print("=" * 60)

func *(lhs: String, rhs: Int) -> String { String(repeating: lhs, count: rhs) }

var addr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyProcessObjectList,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
var size: UInt32 = 0
guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else {
    print("Cannot get process list"); exit(1)
}
let count = Int(size) / MemoryLayout<AudioObjectID>.size
var allIDs = [AudioObjectID](repeating: 0, count: count)
AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &allIDs)

struct ProcessInfo {
    let objID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let appName: String
    let isInput: Bool
    let isOutput: Bool
}

var allProcesses: [ProcessInfo] = []

for id in allIDs {
    // PID
    var pidAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var procPid: UInt32 = 0
    var pidSize = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(id, &pidAddr, 0, nil, &pidSize, &procPid)

    // Bundle ID
    var bidAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var bidVal: Unmanaged<CFString>? = nil
    var bidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var bid = ""
    if AudioObjectGetPropertyData(id, &bidAddr, 0, nil, &bidSize, &bidVal) == noErr {
        bid = bidVal?.takeRetainedValue() as String? ?? ""
    }

    // Is input/output
    var isInputAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var isInput: UInt32 = 0
    var boolSize = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(id, &isInputAddr, 0, nil, &boolSize, &isInput)

    var isOutputAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var isOutput: UInt32 = 0
    AudioObjectGetPropertyData(id, &isOutputAddr, 0, nil, &boolSize, &isOutput)

    let app = NSRunningApplication(processIdentifier: pid_t(procPid))
    let appName = app?.localizedName ?? "?"

    allProcesses.append(ProcessInfo(
        objID: id, pid: pid_t(procPid), bundleID: bid,
        appName: appName, isInput: isInput == 1, isOutput: isOutput == 1
    ))
}

// Show all Brave-related processes
print("\n[1] All audio process objects (\(allProcesses.count) total):")
let braveRelated = allProcesses.filter {
    $0.bundleID.lowercased().contains("brave") ||
    $0.appName.lowercased().contains("brave")
}

print("\n  Brave-related:")
for p in braveRelated {
    print("    ObjID: \(p.objID), PID: \(p.pid), bundle: \(p.bundleID)")
    print("      app: \(p.appName), isInput: \(p.isInput), isOutput: \(p.isOutput)")
}

// Also show processes that are actively outputting audio
print("\n  All processes with isRunningOutput=true:")
for p in allProcesses where p.isOutput {
    print("    ObjID: \(p.objID), PID: \(p.pid), bundle: \(p.bundleID), app: \(p.appName)")
}

// MARK: - Check what the app code actually captures
// The app uses getProcessObjectIDs(for:pid:) which matches by bundleID prefix or PID
let mainBravePID = braveRelated.first(where: { $0.bundleID == "com.brave.Browser" })?.pid
    ?? braveRelated.first?.pid ?? 0
let mainBundleID = "com.brave.Browser"
print("\n[2] Main Brave PID: \(mainBravePID), bundleID: \(mainBundleID)")

// What does the app's matching logic find?
let prefix = mainBundleID + "."
let appMatched = allProcesses.filter { $0.bundleID == mainBundleID || $0.bundleID.hasPrefix(prefix) }
print("  App's bundleID match finds: \(appMatched.map(\.objID))")
for p in appMatched {
    print("    ObjID: \(p.objID), PID: \(p.pid), bundle: \(p.bundleID), isOutput: \(p.isOutput)")
}

// MARK: - Tap each Brave process individually and check for audio
print("\n[3] Testing each Brave process object individually for audio...")
print("    ⚠️  Make sure Brave is actively playing audio!\n")

func testTapForAudio(processObjIDs: [AudioObjectID], label: String) -> (hasAudio: Bool, peak: Float) {
    let tapUUID = UUID()
    let desc = CATapDescription(stereoMixdownOfProcesses: processObjIDs)
    desc.uuid = tapUUID
    desc.isPrivate = false
    desc.muteBehavior = .unmuted

    var tapID = AudioObjectID(kAudioObjectUnknown)
    let tapStatus = AudioHardwareCreateProcessTap(desc, &tapID)
    guard tapStatus == noErr else {
        print("    [\(label)] Tap creation failed: \(tapStatus)")
        return (false, 0)
    }

    let aggDesc: [String: Any] = [
        kAudioAggregateDeviceNameKey: "OSS_Test_\(label)",
        kAudioAggregateDeviceUIDKey: UUID().uuidString,
        kAudioAggregateDeviceIsPrivateKey: 1,
        kAudioAggregateDeviceTapListKey: [[
            kAudioSubTapUIDKey: tapUUID.uuidString,
            kAudioSubTapDriftCompensationKey: false
        ]]
    ]
    var aggDeviceID = AudioDeviceID(kAudioObjectUnknown)
    guard AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggDeviceID) == noErr else {
        AudioHardwareDestroyProcessTap(tapID)
        print("    [\(label)] Aggregate creation failed")
        return (false, 0)
    }

    // Get device sample rate
    var srAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var deviceSR: Float64 = 0
    var srSize = UInt32(MemoryLayout<Float64>.size)
    AudioObjectGetPropertyData(aggDeviceID, &srAddr, 0, nil, &srSize, &deviceSR)
    if deviceSR <= 0 { deviceSR = 48000 }

    Thread.sleep(forTimeInterval: 0.3)

    // Use AVAudioEngine inputNode approach (simpler)
    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    guard let inputAU = inputNode.audioUnit else {
        AudioHardwareDestroyAggregateDevice(aggDeviceID)
        AudioHardwareDestroyProcessTap(tapID)
        return (false, 0)
    }

    var devID = aggDeviceID
    AudioUnitSetProperty(inputAU, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &devID, UInt32(MemoryLayout<AudioDeviceID>.size))

    let hwFormat = inputNode.outputFormat(forBus: 0)
    let format = AVAudioFormat(standardFormatWithSampleRate: deviceSR, channels: 2)!

    var peakLevel: Float = 0
    var bufferCount = 0

    inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { buffer, _ in
        bufferCount += 1
        if let cd = buffer.floatChannelData {
            for i in 0..<Int(buffer.frameLength) {
                let s = abs(cd[0][i])
                if s > peakLevel { peakLevel = s }
            }
        }
    }

    engine.prepare()
    do {
        try engine.start()
    } catch {
        print("    [\(label)] Engine start failed: \(error)")
        inputNode.removeTap(onBus: 0)
        AudioHardwareDestroyAggregateDevice(aggDeviceID)
        AudioHardwareDestroyProcessTap(tapID)
        return (false, 0)
    }

    // Listen for 2 seconds
    Thread.sleep(forTimeInterval: 2.0)

    let result = (hasAudio: peakLevel > 0.001, peak: peakLevel)

    inputNode.removeTap(onBus: 0)
    engine.stop()
    AudioHardwareDestroyAggregateDevice(aggDeviceID)
    AudioHardwareDestroyProcessTap(tapID)

    let peakDB = peakLevel > 0 ? String(format: "%.1f", 20.0 * log10(Double(peakLevel))) : "-inf"
    print("    [\(label)] buffers=\(bufferCount) peak=\(String(format: "%.6f", peakLevel)) (\(peakDB)dB) → \(result.hasAudio ? "✓ HAS AUDIO" : "✗ SILENT")")

    return result
}

// Test each individual process object
for p in braveRelated {
    testTapForAudio(processObjIDs: [p.objID], label: "ObjID=\(p.objID)/PID=\(p.pid)/\(p.bundleID)")
    Thread.sleep(forTimeInterval: 0.3)
}

// Test all Brave processes together (what the app does)
print("\n  Testing ALL Brave processes together:")
let allBraveObjIDs = braveRelated.map(\.objID)
testTapForAudio(processObjIDs: allBraveObjIDs, label: "ALL_BRAVE(\(allBraveObjIDs))")

// MARK: - Also check: what device is Brave actually outputting to?
print("\n[4] Checking system default output device...")
var defaultOutputAddr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
var defaultOutputID: AudioDeviceID = 0
var devSize = UInt32(MemoryLayout<AudioDeviceID>.size)
AudioObjectGetPropertyData(system, &defaultOutputAddr, 0, nil, &devSize, &defaultOutputID)

var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var nameVal: Unmanaged<CFString>? = nil
var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
AudioObjectGetPropertyData(defaultOutputID, &nameAddr, 0, nil, &nameSize, &nameVal)
let defaultName = nameVal?.takeRetainedValue() as String? ?? "?"
print("  Default output device: \(defaultName) (ID: \(defaultOutputID))")

// Check if Brave's tap is muted in the app
print("\n[5] Checking app's tap muteBehavior...")
print("  The app uses .muted — this mutes the original output to the default device")
print("  If the capture also gets silence, the tap itself may not be capturing properly")

// MARK: - Test: tap with .muted vs .unmuted
print("\n[6] Comparing .muted vs .unmuted tap behavior...")

func testTapMuteBehavior(processObjIDs: [AudioObjectID], muted: Bool) -> Float {
    let tapUUID = UUID()
    let desc = CATapDescription(stereoMixdownOfProcesses: processObjIDs)
    desc.uuid = tapUUID
    desc.isPrivate = false
    desc.muteBehavior = muted ? .muted : .unmuted

    var tapID = AudioObjectID(kAudioObjectUnknown)
    guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr else { return -1 }

    let aggDesc: [String: Any] = [
        kAudioAggregateDeviceNameKey: "OSS_MuteTest",
        kAudioAggregateDeviceUIDKey: UUID().uuidString,
        kAudioAggregateDeviceIsPrivateKey: 1,
        kAudioAggregateDeviceTapListKey: [[
            kAudioSubTapUIDKey: tapUUID.uuidString,
            kAudioSubTapDriftCompensationKey: false
        ]]
    ]
    var aggDeviceID = AudioDeviceID(kAudioObjectUnknown)
    guard AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggDeviceID) == noErr else {
        AudioHardwareDestroyProcessTap(tapID)
        return -1
    }

    var srAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var deviceSR: Float64 = 0
    var srSize = UInt32(MemoryLayout<Float64>.size)
    AudioObjectGetPropertyData(aggDeviceID, &srAddr, 0, nil, &srSize, &deviceSR)
    if deviceSR <= 0 { deviceSR = 48000 }

    Thread.sleep(forTimeInterval: 0.3)

    // AUHAL approach (matches the app)
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

    let captureFormat = AVAudioFormat(standardFormatWithSampleRate: deviceSR, channels: 2)!
    var outASBD = captureFormat.streamDescription.pointee
    AudioUnitSetProperty(captureUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &outASBD, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

    class SimpleCtx {
        let captureUnit: AudioUnit
        let format: AVAudioFormat
        var peak: Float = 0
        var okCount: Int = 0
        var errCount: Int = 0
        var lastErr: OSStatus = 0
        init(_ cu: AudioUnit, _ f: AVAudioFormat) { captureUnit = cu; format = f }
    }
    let ctx = SimpleCtx(captureUnit, captureFormat)
    let ctxRetained = Unmanaged.passRetained(ctx)

    var cb = AURenderCallbackStruct(
        inputProc: { (inRefCon, ioActionFlags, inTimeStamp, _, inNumberFrames, _) -> OSStatus in
            let c = Unmanaged<SimpleCtx>.fromOpaque(inRefCon).takeUnretainedValue()
            guard let buffer = AVAudioPCMBuffer(pcmFormat: c.format, frameCapacity: inNumberFrames) else { return noErr }
            buffer.frameLength = inNumberFrames
            let status = withUnsafeMutablePointer(to: &buffer.mutableAudioBufferList.pointee) { ablPtr in
                AudioUnitRender(c.captureUnit, ioActionFlags, inTimeStamp, 1, inNumberFrames, ablPtr)
            }
            if status != noErr { c.errCount += 1; c.lastErr = status; return noErr }
            c.okCount += 1
            if let cd = buffer.floatChannelData {
                for i in 0..<Int(buffer.frameLength) {
                    let s = abs(cd[0][i])
                    if s > c.peak { c.peak = s }
                }
            }
            return noErr
        },
        inputProcRefCon: ctxRetained.toOpaque()
    )

    AudioUnitSetProperty(captureUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
    AudioUnitInitialize(captureUnit)
    AudioOutputUnitStart(captureUnit)

    Thread.sleep(forTimeInterval: 2.0)

    let peak = ctx.peak
    let ok = ctx.okCount
    let err = ctx.errCount
    let lastErr = ctx.lastErr

    AudioOutputUnitStop(captureUnit)
    AudioUnitUninitialize(captureUnit)
    AudioComponentInstanceDispose(captureUnit)
    ctxRetained.release()
    AudioHardwareDestroyAggregateDevice(aggDeviceID)
    AudioHardwareDestroyProcessTap(tapID)

    let peakDB = peak > 0 ? String(format: "%.1f", 20.0 * log10(Double(peak))) : "-inf"
    print("  \(muted ? "MUTED" : "UNMUTED"): ok=\(ok) err=\(err) lastErr=\(lastErr) peak=\(String(format: "%.6f", peak)) (\(peakDB)dB)")

    return peak
}

let allBraveIDs = braveRelated.map(\.objID)
print("  Testing with process objects: \(allBraveIDs)")
let mutedPeak = testTapMuteBehavior(processObjIDs: allBraveIDs, muted: true)
Thread.sleep(forTimeInterval: 0.5)
let unmutedPeak = testTapMuteBehavior(processObjIDs: allBraveIDs, muted: false)

print("\n" + "=" * 60)
print("SUMMARY")
print("=" * 60)

if mutedPeak < 0.001 && unmutedPeak < 0.001 {
    print("❌ Both muted and unmuted taps are SILENT")
    print("   Possible causes:")
    print("   1. Brave is not actually producing audio (check tab has audio icon)")
    print("   2. Wrong process objects are being tapped")
    print("   3. Brave uses a non-standard audio path")

    // Check if there are utility/renderer processes we're missing
    let allBravePIDs = Set(braveRelated.map(\.pid))
    let braveCLIProcesses = allProcesses.filter { p in
        let app = NSRunningApplication(processIdentifier: p.pid)
        let execURL = app?.executableURL?.lastPathComponent ?? ""
        return execURL.lowercased().contains("brave") || p.bundleID.lowercased().contains("brave")
    }
    if braveCLIProcesses.count != braveRelated.count {
        print("\n   Additional Brave-like processes found by executable name:")
        for p in braveCLIProcesses where !allBravePIDs.contains(p.pid) {
            print("     ObjID: \(p.objID), PID: \(p.pid), bundle: \(p.bundleID)")
        }
    }

    // List ALL processes that are outputting audio right now
    let outputting = allProcesses.filter { $0.isOutput }
    print("\n   Processes currently outputting audio:")
    for p in outputting {
        print("     ObjID: \(p.objID), PID: \(p.pid), bundle: \(p.bundleID), app: \(p.appName)")
    }
} else if mutedPeak < 0.001 && unmutedPeak > 0.001 {
    print("⚠️  Unmuted tap captures audio but muted tap is SILENT")
    print("   This suggests .muted behavior may block the tap's own capture")
} else {
    print("✓ Audio captured successfully (muted peak: \(mutedPeak), unmuted peak: \(unmutedPeak))")
}

print("\nDone")
