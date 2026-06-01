#!/usr/bin/env swift
/// Diagnostic: replicate the FULL app flow — AUHAL capture + AVAudioEngine playback
/// to isolate whether the combination causes silence.

import CoreAudio
import AVFoundation
import AppKit
import Foundation

let system = AudioObjectID(kAudioObjectSystemObject)

guard let braveApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.brave.Browser" }) else {
    print("Brave not running"); exit(1)
}
let bundleID = braveApp.bundleIdentifier!

// ── 1. Find process objects (same as app) ──
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
        var bidVal: Unmanaged<CFString>? = nil; var bidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(id, &bidAddr, 0, nil, &bidSize, &bidVal) == noErr, let bid = bidVal?.takeRetainedValue() as String? {
            if bid == bundleID || bid.hasPrefix(prefix) {
                // Check isRunningOutput
                var roAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                var isRO: UInt32 = 0; var roSize = UInt32(MemoryLayout<UInt32>.size)
                AudioObjectGetPropertyData(id, &roAddr, 0, nil, &roSize, &isRO)
                var pidAddr2 = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                var p: UInt32 = 0; var ps = UInt32(MemoryLayout<UInt32>.size)
                AudioObjectGetPropertyData(id, &pidAddr2, 0, nil, &ps, &p)
                print("  Process obj \(id): pid=\(p) bundleID=\(bid) isRunningOutput=\(isRO)")
                matched.append(id)
            }
        }
    }
    return matched
}

let processObjIDs = getProcessObjectIDs()
guard !processObjIDs.isEmpty else { print("No process objects"); exit(1) }
print("Process objects: \(processObjIDs)")

// ── Find MacBook Pro Speakers ──
func findSpeakers() -> (id: AudioDeviceID, uid: String)? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return nil }
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids)
    for id in ids {
        var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var nameVal: Unmanaged<CFString>? = nil; var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &nameVal) == noErr,
           let name = nameVal?.takeRetainedValue() as String?, name.contains("MacBook Pro Speaker") {
            var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var uidVal: Unmanaged<CFString>? = nil; var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, &uidVal)
            let uid = (uidVal?.takeRetainedValue() as String?) ?? ""
            return (id, uid)
        }
    }
    return nil
}

guard let speakers = findSpeakers() else { print("Speakers not found"); exit(1) }
print("Speakers: id=\(speakers.id) uid=\(speakers.uid)")

// ── 2. Create process tap ──
let tapUUID = UUID()
let desc = CATapDescription(stereoMixdownOfProcesses: processObjIDs)
desc.uuid = tapUUID; desc.isPrivate = false; desc.muteBehavior = .muted
var tapID = AudioObjectID(kAudioObjectUnknown)
guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr else { print("Tap create failed"); exit(1) }

var tapUIDAddr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var tapUIDVal: Unmanaged<CFString>? = nil; var tapUIDSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
let actualTapUID: String
if AudioObjectGetPropertyData(tapID, &tapUIDAddr, 0, nil, &tapUIDSize, &tapUIDVal) == noErr, let uid = tapUIDVal?.takeRetainedValue() as String? {
    actualTapUID = uid
} else { actualTapUID = tapUUID.uuidString }
print("Tap \(tapID) UID: set=\(tapUUID.uuidString) actual=\(actualTapUID)")

// ── 3. Create aggregate device ──
let aggDict: [String: Any] = [
    kAudioAggregateDeviceNameKey: "OSS_Route_Test",
    kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceIsPrivateKey: 1,
    kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: actualTapUID, kAudioSubTapDriftCompensationKey: false]]
]
var aggID = AudioDeviceID(kAudioObjectUnknown)
guard AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &aggID) == noErr else {
    AudioHardwareDestroyProcessTap(tapID); print("Aggregate failed"); exit(1)
}
print("Aggregate device: \(aggID)")

var srAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var deviceSR: Float64 = 0; var srSize = UInt32(MemoryLayout<Float64>.size)
AudioObjectGetPropertyData(aggID, &srAddr, 0, nil, &srSize, &deviceSR)
if deviceSR <= 0 { deviceSR = 48000 }
print("Aggregate sample rate: \(deviceSR)")

Thread.sleep(forTimeInterval: 0.5)

// ══════════════════════════════════════════════════════════
// TEST A: Standalone AUHAL capture only (no AVAudioEngine)
// ══════════════════════════════════════════════════════════
print("\n--- TEST A: Standalone AUHAL capture (no playback engine) ---")

var captureDesc = AudioComponentDescription(
    componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
    componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
)
let component = AudioComponentFindNext(nil, &captureDesc)!
var optCU: AudioUnit?; AudioComponentInstanceNew(component, &optCU); let captureUnit = optCU!

var one: UInt32 = 1; var zero: UInt32 = 0
AudioUnitSetProperty(captureUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, UInt32(MemoryLayout<UInt32>.size))
AudioUnitSetProperty(captureUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, UInt32(MemoryLayout<UInt32>.size))

var devID = aggID
AudioUnitSetProperty(captureUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &devID, UInt32(MemoryLayout<AudioDeviceID>.size))

let captureFormat = AVAudioFormat(standardFormatWithSampleRate: deviceSR, channels: 2)!
var outASBD = captureFormat.streamDescription.pointee
AudioUnitSetProperty(captureUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &outASBD, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

class TestCtx {
    let captureUnit: AudioUnit
    let format: AVAudioFormat
    var bufCount: UInt64 = 0; var okCount: UInt64 = 0; var errCount: UInt64 = 0
    var peak: Float = 0; var lastRenderFlags: UInt32 = 0
    var mDataWasNull = false
    init(_ cu: AudioUnit, _ f: AVAudioFormat) { captureUnit = cu; format = f }
}

let ctxA = TestCtx(captureUnit, captureFormat)
let ctxARetained = Unmanaged.passRetained(ctxA)

var cbA = AURenderCallbackStruct(
    inputProc: { (inRefCon, ioActionFlags, inTimeStamp, _, inNumberFrames, _) -> OSStatus in
        let c = Unmanaged<TestCtx>.fromOpaque(inRefCon).takeUnretainedValue()
        c.bufCount += 1
        guard let buffer = AVAudioPCMBuffer(pcmFormat: c.format, frameCapacity: inNumberFrames) else { return noErr }
        buffer.frameLength = inNumberFrames

        // Check mData before render
        let abl = buffer.mutableAudioBufferList
        if abl.pointee.mBuffers.mData == nil { c.mDataWasNull = true }

        let st = AudioUnitRender(c.captureUnit, ioActionFlags, inTimeStamp, 1, inNumberFrames, abl)
        c.lastRenderFlags = ioActionFlags.pointee.rawValue
        if st != noErr { c.errCount += 1; return noErr }
        c.okCount += 1

        // Check raw mData bytes after render
        if let data = abl.pointee.mBuffers.mData {
            let floats = data.assumingMemoryBound(to: Float.self)
            for i in 0..<Int(inNumberFrames) {
                let s = abs(floats[i]); if s > c.peak { c.peak = s }
            }
        }
        return noErr
    },
    inputProcRefCon: ctxARetained.toOpaque()
)

AudioUnitSetProperty(captureUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cbA, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
AudioUnitInitialize(captureUnit)
AudioOutputUnitStart(captureUnit)

Thread.sleep(forTimeInterval: 3.0)
AudioOutputUnitStop(captureUnit)

print("  buffers=\(ctxA.bufCount) ok=\(ctxA.okCount) err=\(ctxA.errCount) peak=\(ctxA.peak)")
print("  mDataWasNull=\(ctxA.mDataWasNull) lastRenderFlags=\(ctxA.lastRenderFlags)")
let testAPeak = ctxA.peak
print("  Result: \(ctxA.peak > 0.001 ? "✓ HAS AUDIO" : "✗ SILENCE")")

// Don't dispose yet — we reuse the capture unit

// ══════════════════════════════════════════════════════════
// TEST B: AUHAL capture + AVAudioEngine playback (app flow)
// ══════════════════════════════════════════════════════════
print("\n--- TEST B: AUHAL capture + AVAudioEngine playback (full app flow) ---")

// Reset context
let ctxB = TestCtx(captureUnit, captureFormat)
let ctxBRetained = Unmanaged.passRetained(ctxB)

// Create playback engine
let engine = AVAudioEngine()
let playerNode = AVAudioPlayerNode()
engine.attach(playerNode)

// Disable input on output AUHAL
if let outputAU = engine.outputNode.audioUnit {
    AudioUnitSetProperty(outputAU, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &zero, UInt32(MemoryLayout<UInt32>.size))
}

do {
    try engine.outputNode.auAudioUnit.setDeviceID(speakers.id)
} catch {
    print("Failed to set output device: \(error)")
}

let outputHWFormat = engine.outputNode.outputFormat(forBus: 0)
print("  Output HW: \(outputHWFormat.channelCount) ch, \(Int(outputHWFormat.sampleRate)) Hz")

let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: outputHWFormat.sampleRate > 0 ? outputHWFormat.sampleRate : 48000,
                                   channels: outputHWFormat.channelCount > 0 ? outputHWFormat.channelCount : 2)!
engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)
engine.mainMixerNode.outputVolume = 1.0

var converter: AVAudioConverter? = nil
let needsConversion = abs(deviceSR - playbackFormat.sampleRate) > 1.0 || 2 != playbackFormat.channelCount
if needsConversion {
    converter = AVAudioConverter(from: captureFormat, to: playbackFormat)
    print("  Converter: 2ch/\(Int(deviceSR))Hz -> \(playbackFormat.channelCount)ch/\(Int(playbackFormat.sampleRate))Hz")
}

// New callback that also forwards to playerNode
var cbB = AURenderCallbackStruct(
    inputProc: { (inRefCon, ioActionFlags, inTimeStamp, _, inNumberFrames, _) -> OSStatus in
        let c = Unmanaged<TestCtx>.fromOpaque(inRefCon).takeUnretainedValue()
        c.bufCount += 1
        guard let buffer = AVAudioPCMBuffer(pcmFormat: c.format, frameCapacity: inNumberFrames) else { return noErr }
        buffer.frameLength = inNumberFrames

        let abl = buffer.mutableAudioBufferList
        let st = AudioUnitRender(c.captureUnit, ioActionFlags, inTimeStamp, 1, inNumberFrames, abl)
        c.lastRenderFlags = ioActionFlags.pointee.rawValue
        if st != noErr { c.errCount += 1; return noErr }
        c.okCount += 1

        if let data = abl.pointee.mBuffers.mData {
            let floats = data.assumingMemoryBound(to: Float.self)
            for i in 0..<Int(inNumberFrames) {
                let s = abs(floats[i]); if s > c.peak { c.peak = s }
            }
        }
        return noErr
    },
    inputProcRefCon: ctxBRetained.toOpaque()
)

AudioUnitSetProperty(captureUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cbB, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

engine.prepare()
try! engine.start()
playerNode.play()
AudioOutputUnitStart(captureUnit)

Thread.sleep(forTimeInterval: 3.0)
AudioOutputUnitStop(captureUnit)
playerNode.stop()
engine.stop()

print("  buffers=\(ctxB.bufCount) ok=\(ctxB.okCount) err=\(ctxB.errCount) peak=\(ctxB.peak)")
print("  lastRenderFlags=\(ctxB.lastRenderFlags)")
print("  Result: \(ctxB.peak > 0.001 ? "✓ HAS AUDIO" : "✗ SILENCE")")

// ══════════════════════════════════════════════════════════
// TEST C: AVAudioEngine.inputNode.installTap (POC approach)
// ══════════════════════════════════════════════════════════
print("\n--- TEST C: AVAudioEngine.inputNode.installTap (POC approach) ---")

// Stop and dispose the standalone AUHAL first
AudioUnitUninitialize(captureUnit)
AudioComponentInstanceDispose(captureUnit)

// We need a fresh tap + aggregate for this test since we destroyed the AUHAL
// Actually, we can reuse the aggregate device

let captureEngine = AVAudioEngine()
let inputNode = captureEngine.inputNode
if let auHAL = inputNode.audioUnit {
    var d = aggID
    let setSt = AudioUnitSetProperty(auHAL, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &d, UInt32(MemoryLayout<AudioDeviceID>.size))
    print("  Set input device status: \(setSt)")
} else {
    print("  inputNode.audioUnit is nil!")
}

let tapFormat = AVAudioFormat(standardFormatWithSampleRate: deviceSR, channels: 2)!
var installTapPeak: Float = 0
var installTapBufs: UInt64 = 0

inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, _ in
    installTapBufs += 1
    guard let cd = buffer.floatChannelData else { return }
    for i in 0..<Int(buffer.frameLength) {
        let s = abs(cd[0][i]); if s > installTapPeak { installTapPeak = s }
    }
}

do {
    try captureEngine.start()
    print("  Capture engine started")
} catch {
    print("  Capture engine failed: \(error)")
}

Thread.sleep(forTimeInterval: 3.0)
inputNode.removeTap(onBus: 0)
captureEngine.stop()

print("  buffers=\(installTapBufs) peak=\(installTapPeak)")
print("  Result: \(installTapPeak > 0.001 ? "✓ HAS AUDIO" : "✗ SILENCE")")

// ── Cleanup ──
AudioHardwareDestroyAggregateDevice(aggID)
AudioHardwareDestroyProcessTap(tapID)
ctxARetained.release()
ctxBRetained.release()

print("\n--- SUMMARY ---")
print("  TEST A (AUHAL only):      peak=\(testAPeak) \(testAPeak > 0.001 ? "AUDIO" : "SILENCE")")
print("  TEST B (AUHAL+Engine):    peak=\(ctxB.peak) \(ctxB.peak > 0.001 ? "AUDIO" : "SILENCE")")
print("  TEST C (installTap/POC):  peak=\(installTapPeak) \(installTapPeak > 0.001 ? "AUDIO" : "SILENCE")")
