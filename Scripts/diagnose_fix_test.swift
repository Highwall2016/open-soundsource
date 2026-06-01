#!/usr/bin/env swift
/// Test: fix capture format to match device sample rate, with proper callback-based rendering.
/// Logs actual render error codes.

import CoreAudio
import AVFoundation
import AppKit
import Foundation

let system = AudioObjectID(kAudioObjectSystemObject)

guard let braveApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.brave.Browser" }) else {
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
    kAudioAggregateDeviceNameKey: "OSS_Diag3",
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

// Get device sample rate
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

// BEFORE: Check default format
var defaultASBD = AudioStreamBasicDescription()
var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
AudioUnitGetProperty(captureUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &defaultASBD, &asbdSize)
print("Default AUHAL output format: \(defaultASBD.mChannelsPerFrame)ch \(Int(defaultASBD.mSampleRate))Hz")

// *** THE FIX: Use the device's sample rate, not the AUHAL's default ***
let captureSR = deviceSR > 0 ? deviceSR : 48000
let captureCh: UInt32 = defaultASBD.mChannelsPerFrame > 0 ? defaultASBD.mChannelsPerFrame : 2
let captureFormat = AVAudioFormat(standardFormatWithSampleRate: captureSR, channels: AVAudioChannelCount(captureCh))!
var outASBD = captureFormat.streamDescription.pointee
let setStatus = AudioUnitSetProperty(captureUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &outASBD, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
print("Set AUHAL output format to \(Int(captureSR))Hz: OSStatus \(setStatus)")

// Verify
var verifyASBD = AudioStreamBasicDescription()
AudioUnitGetProperty(captureUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &verifyASBD, &asbdSize)
print("Verified format: \(verifyASBD.mChannelsPerFrame)ch \(Int(verifyASBD.mSampleRate))Hz")

// Find speaker
func findSpeaker() -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return nil }
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return nil }

    for id in ids {
        var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var nameVal: Unmanaged<CFString>? = nil
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &nameVal) == noErr {
            if let name = nameVal?.takeRetainedValue() as String?, name.lowercased().contains("speaker") {
                return id
            }
        }
    }
    return nil
}

guard let speakerID = findSpeaker() else { print("No speaker found"); exit(1) }
print("Speaker device ID: \(speakerID)")

// Setup playback engine
let engine = AVAudioEngine()
let playerNode = AVAudioPlayerNode()
engine.attach(playerNode)

if let outputAU = engine.outputNode.audioUnit {
    AudioUnitSetProperty(outputAU, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &zero, UInt32(MemoryLayout<UInt32>.size))
}

try! engine.outputNode.auAudioUnit.setDeviceID(speakerID)
let outputHWFormat = engine.outputNode.outputFormat(forBus: 0)
let outputSR = outputHWFormat.sampleRate > 0 ? outputHWFormat.sampleRate : 48000
let outputCh = outputHWFormat.channelCount > 0 ? outputHWFormat.channelCount : 2
print("Output format: \(outputCh)ch \(Int(outputSR))Hz")

let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: outputSR, channels: AVAudioChannelCount(outputCh))!
engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)
engine.mainMixerNode.outputVolume = 1.0

// Converter setup
var converter: AVAudioConverter? = nil
if abs(captureSR - outputSR) > 1.0 || captureCh != UInt32(outputCh) {
    converter = AVAudioConverter(from: captureFormat, to: playbackFormat)
    print("Converter: \(captureCh)ch/\(Int(captureSR))Hz → \(outputCh)ch/\(Int(outputSR))Hz")
}

// Shared context
class Ctx {
    let captureUnit: AudioUnit
    let playerNode: AVAudioPlayerNode
    let captureFormat: AVAudioFormat
    let playbackFormat: AVAudioFormat
    let converter: AVAudioConverter?
    var bufCount: UInt64 = 0
    var okCount: UInt64 = 0
    var errCount: UInt64 = 0
    var lastError: OSStatus = 0
    var peak: Float = 0

    init(captureUnit: AudioUnit, playerNode: AVAudioPlayerNode,
         captureFormat: AVAudioFormat, playbackFormat: AVAudioFormat,
         converter: AVAudioConverter?) {
        self.captureUnit = captureUnit
        self.playerNode = playerNode
        self.captureFormat = captureFormat
        self.playbackFormat = playbackFormat
        self.converter = converter
    }
}

let ctx = Ctx(captureUnit: captureUnit, playerNode: playerNode,
              captureFormat: captureFormat, playbackFormat: playbackFormat, converter: converter)
let ctxRetained = Unmanaged.passRetained(ctx)

var callbackStruct = AURenderCallbackStruct(
    inputProc: { (inRefCon, ioActionFlags, inTimeStamp, _, inNumberFrames, _) -> OSStatus in
        let c = Unmanaged<Ctx>.fromOpaque(inRefCon).takeUnretainedValue()
        c.bufCount += 1

        guard let buffer = AVAudioPCMBuffer(pcmFormat: c.captureFormat, frameCapacity: inNumberFrames) else { return noErr }
        buffer.frameLength = inNumberFrames

        let status = withUnsafeMutablePointer(to: &buffer.mutableAudioBufferList.pointee) { ablPtr in
            AudioUnitRender(c.captureUnit, ioActionFlags, inTimeStamp, 1, inNumberFrames, ablPtr)
        }
        if status != noErr {
            c.errCount += 1
            c.lastError = status
            return noErr
        }
        c.okCount += 1

        // Measure peak
        if let cd = buffer.floatChannelData {
            for i in 0..<Int(buffer.frameLength) {
                let s = abs(cd[0][i])
                if s > c.peak { c.peak = s }
            }
        }

        // Forward to player
        if let converter = c.converter {
            let ratio = c.playbackFormat.sampleRate / c.captureFormat.sampleRate
            let outCap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: c.playbackFormat, frameCapacity: outCap) else { return noErr }
            var err: NSError?
            var consumed = false
            converter.convert(to: outBuf, error: &err) { _, outStatus in
                if !consumed { consumed = true; outStatus.pointee = .haveData; return buffer }
                outStatus.pointee = .noDataNow; return nil
            }
            if err == nil && outBuf.frameLength > 0 {
                c.playerNode.scheduleBuffer(outBuf)
            }
        } else {
            c.playerNode.scheduleBuffer(buffer)
        }
        return noErr
    },
    inputProcRefCon: ctxRetained.toOpaque()
)

AudioUnitSetProperty(captureUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
AudioUnitInitialize(captureUnit)

engine.prepare()
try! engine.start()
playerNode.play()
AudioOutputUnitStart(captureUnit)

print("\n🎧 Listening for 6 seconds (play audio in Brave!)...\n")

for sec in 1...6 {
    Thread.sleep(forTimeInterval: 1.0)
    let peakDB = ctx.peak > 0 ? 20.0 * log10(Double(ctx.peak)) : -120.0
    print("  [\(sec)s] callbacks=\(ctx.bufCount) ok=\(ctx.okCount) err=\(ctx.errCount) lastErr=\(ctx.lastError) peak=\(String(format: "%.4f", ctx.peak)) (\(String(format: "%.1f", peakDB))dB) engine=\(engine.isRunning) player=\(playerNode.isPlaying)")
}

print("\n--- RESULT ---")
if ctx.okCount > 0 && ctx.peak > 0.001 {
    print("✅ AUDIO IS FLOWING! Fix confirmed: use device sample rate, not AUHAL default.")
    print("   Peak level: \(ctx.peak) (\(String(format: "%.1f", 20.0 * log10(Double(ctx.peak))))dB)")
} else if ctx.okCount > 0 {
    print("⚠️  Renders succeed but audio is silent — Brave may not be producing audio")
} else {
    print("❌ Still failing: error code \(ctx.lastError)")
}

// Cleanup
AudioOutputUnitStop(captureUnit)
AudioUnitUninitialize(captureUnit)
AudioComponentInstanceDispose(captureUnit)
ctxRetained.release()
playerNode.stop()
engine.stop()
AudioHardwareDestroyAggregateDevice(aggDeviceID)
AudioHardwareDestroyProcessTap(tapID)
print("Done")
