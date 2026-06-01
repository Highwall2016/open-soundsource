#!/usr/bin/env swift
/// Diagnose audio routing from Brave Browser to MacBook Pro speakers.
/// Checks every step: process objects, tap, aggregate, capture, playback.
/// Usage: swift Scripts/diagnose_routing.swift [pid]

import CoreAudio
import AVFoundation
import AppKit
import Foundation

print("=" * 60)
print("Open Sound Source — Routing Diagnostics")
print("=" * 60)

// MARK: - Step 1: Find Brave Browser
print("\n[STEP 1] Finding Brave Browser...")

let runningApps = NSWorkspace.shared.runningApplications
let braveApps = runningApps.filter { $0.bundleIdentifier?.contains("brave") == true || $0.localizedName?.contains("Brave") == true }

if braveApps.isEmpty {
    print("❌ Brave Browser not found running!")
    exit(1)
}

for app in braveApps {
    print("  Found: \(app.localizedName ?? "?") (PID: \(app.processIdentifier), bundle: \(app.bundleIdentifier ?? "?"))")
}

let bravePID: pid_t
if CommandLine.arguments.count >= 2, let pid = Int32(CommandLine.arguments[1]) {
    bravePID = pid
} else {
    bravePID = braveApps[0].processIdentifier
}
let bundleID = NSRunningApplication(processIdentifier: bravePID)?.bundleIdentifier ?? ""
print("  Using PID: \(bravePID), bundleID: \(bundleID)")

// MARK: - Step 2: Find audio process objects
print("\n[STEP 2] Finding audio process objects...")

let system = AudioObjectID(kAudioObjectSystemObject)

func getAllProcessObjects() -> [(id: AudioObjectID, pid: pid_t, bundleID: String)] {
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

    var result: [(id: AudioObjectID, pid: pid_t, bundleID: String)] = []
    for id in ids {
        var pidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var procPid: UInt32 = 0
        var pidSize = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &pidAddr, 0, nil, &pidSize, &procPid)

        var bidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var bidVal: Unmanaged<CFString>? = nil
        var bidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var bid = ""
        if AudioObjectGetPropertyData(id, &bidAddr, 0, nil, &bidSize, &bidVal) == noErr {
            bid = bidVal?.takeRetainedValue() as String? ?? ""
        }

        result.append((id: id, pid: pid_t(procPid), bundleID: bid))
    }
    return result
}

let allProcs = getAllProcessObjects()
let braveProcs = allProcs.filter { $0.bundleID == bundleID || $0.bundleID.hasPrefix(bundleID + ".") || $0.pid == bravePID }

print("  Total audio processes: \(allProcs.count)")
print("  Brave-related processes:")
if braveProcs.isEmpty {
    // Also show all Brave-related by PID or name
    let braveRenderers = allProcs.filter { proc in
        let app = NSRunningApplication(processIdentifier: proc.pid)
        return app?.localizedName?.contains("Brave") == true || proc.bundleID.lowercased().contains("brave")
    }
    if braveRenderers.isEmpty {
        print("  ❌ No audio process objects found for Brave!")
        print("\n  All audio processes for reference:")
        for proc in allProcs {
            let appName = NSRunningApplication(processIdentifier: proc.pid)?.localizedName ?? "?"
            print("    ObjID: \(proc.id), PID: \(proc.pid), bundle: \(proc.bundleID), app: \(appName)")
        }
        print("\n  ⚠️  Brave may not be producing audio. Play something in Brave first!")
        exit(1)
    } else {
        for proc in braveRenderers {
            print("    ObjID: \(proc.id), PID: \(proc.pid), bundle: \(proc.bundleID)")
        }
    }
} else {
    for proc in braveProcs {
        print("    ObjID: \(proc.id), PID: \(proc.pid), bundle: \(proc.bundleID)")
    }
}

let processObjIDs: [AudioObjectID]
if !braveProcs.isEmpty {
    processObjIDs = braveProcs.map(\.id)
} else {
    let braveRenderers = allProcs.filter { proc in
        proc.bundleID.lowercased().contains("brave") || proc.pid == bravePID
    }
    processObjIDs = braveRenderers.map(\.id)
}

guard !processObjIDs.isEmpty else {
    print("❌ Cannot proceed without process objects")
    exit(1)
}
print("  ✓ Using \(processObjIDs.count) process objects: \(processObjIDs)")

// MARK: - Step 3: List output devices
print("\n[STEP 3] Listing output devices...")

func listOutputDevices() -> [(id: AudioDeviceID, name: String, uid: String, sampleRate: Float64, channels: UInt32)] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }

    var devices: [(id: AudioDeviceID, name: String, uid: String, sampleRate: Float64, channels: UInt32)] = []
    for id in ids {
        var chanAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var chanSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &chanAddr, 0, nil, &chanSize) == noErr, chanSize > 0 else { continue }
        let bufPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { bufPtr.deallocate() }
        guard AudioObjectGetPropertyData(id, &chanAddr, 0, nil, &chanSize, bufPtr) == noErr else { continue }
        let bufList = UnsafeMutableAudioBufferListPointer(bufPtr)
        var totalCh: UInt32 = 0
        for b in bufList { totalCh += b.mNumberChannels }
        guard totalCh > 0 else { continue }

        var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var nameVal: Unmanaged<CFString>? = nil
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &nameVal) == noErr,
              let name = nameVal?.takeRetainedValue() as String? else { continue }

        var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uidVal: Unmanaged<CFString>? = nil
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, &uidVal) == noErr,
              let uid = uidVal?.takeRetainedValue() as String? else { continue }

        var srAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var sr: Float64 = 0
        var srSize = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(id, &srAddr, 0, nil, &srSize, &sr)

        devices.append((id: id, name: name, uid: uid, sampleRate: sr, channels: totalCh))
    }
    return devices
}

let allDevices = listOutputDevices()
var speakerDevice: (id: AudioDeviceID, name: String, uid: String, sampleRate: Float64, channels: UInt32)?

for (i, d) in allDevices.enumerated() {
    let marker = d.name.lowercased().contains("speaker") || d.name.lowercased().contains("macbook") ? " ← SPEAKER" : ""
    print("  [\(i)] \(d.name) (ID: \(d.id), \(Int(d.sampleRate))Hz, \(d.channels)ch)\(marker)")
    if d.name.lowercased().contains("speaker") || d.name.lowercased().contains("macbook") {
        speakerDevice = d
    }
}

guard let speaker = speakerDevice else {
    print("❌ MacBook Pro speaker not found!")
    exit(1)
}
print("  ✓ Target: \(speaker.name) (ID: \(speaker.id), \(Int(speaker.sampleRate))Hz, \(speaker.channels)ch)")

// Check if speaker is alive
var aliveAddr = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyDeviceIsAlive,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
var isAlive: UInt32 = 0
var aliveSize = UInt32(MemoryLayout<UInt32>.size)
if AudioObjectGetPropertyData(speaker.id, &aliveAddr, 0, nil, &aliveSize, &isAlive) == noErr {
    print("  Speaker alive: \(isAlive == 1 ? "✓ YES" : "❌ NO")")
}

// Check speaker volume
var volAddr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
    mScope: kAudioDevicePropertyScopeOutput,
    mElement: kAudioObjectPropertyElementMain
)
var volume: Float32 = 0
var volSize = UInt32(MemoryLayout<Float32>.size)
if AudioObjectGetPropertyData(speaker.id, &volAddr, 0, nil, &volSize, &volume) == noErr {
    print("  Speaker volume: \(String(format: "%.0f%%", volume * 100))")
    if volume < 0.01 {
        print("  ⚠️  Speaker volume is very low or muted!")
    }
}

// Check speaker mute state
var muteAddr = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyMute,
    mScope: kAudioDevicePropertyScopeOutput,
    mElement: kAudioObjectPropertyElementMain
)
var isMuted: UInt32 = 0
var muteSize = UInt32(MemoryLayout<UInt32>.size)
if AudioObjectGetPropertyData(speaker.id, &muteAddr, 0, nil, &muteSize, &isMuted) == noErr {
    print("  Speaker muted: \(isMuted == 1 ? "⚠️  YES — UNMUTE IT!" : "✓ NO")")
}

// MARK: - Step 4: Create process tap
print("\n[STEP 4] Creating process tap...")

let tapUUID = UUID()
let desc = CATapDescription(stereoMixdownOfProcesses: processObjIDs)
desc.uuid = tapUUID
desc.isPrivate = false
desc.muteBehavior = .unmuted  // Use unmuted for diagnosis so we can compare

var tapID = AudioObjectID(kAudioObjectUnknown)
let tapStatus = AudioHardwareCreateProcessTap(desc, &tapID)
guard tapStatus == noErr else {
    print("  ❌ CreateProcessTap failed: OSStatus \(tapStatus)")
    exit(1)
}
print("  ✓ Created tap ID \(tapID)")

// Query the tap's actual UID
var tapUIDAddr = AudioObjectPropertyAddress(
    mSelector: kAudioTapPropertyUID,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
var tapUIDVal: CFString? = nil
var tapUIDSize = UInt32(MemoryLayout<CFString?>.size)
let tapUIDStatus = AudioObjectGetPropertyData(tapID, &tapUIDAddr, 0, nil, &tapUIDSize, &tapUIDVal)
let tapUIDString: String
if tapUIDStatus == noErr, let uid = tapUIDVal as String? {
    tapUIDString = uid
    print("  ✓ Tap UID: \(tapUIDString)")
} else {
    tapUIDString = tapUUID.uuidString
    print("  ⚠️ Using UUID as tap UID: \(tapUIDString)")
}

// MARK: - Step 5: Create aggregate device
print("\n[STEP 5] Creating tap-only aggregate device...")

// NOTE: The app code uses tapUUID.uuidString as the subTapUID,
// but the correct value should be the tap's actual UID property.
// Let's test BOTH to see which one works.

let subTapDict: [String: Any] = [
    kAudioSubTapUIDKey: tapUIDString,
    kAudioSubTapDriftCompensationKey: false
]
let aggDesc: [String: Any] = [
    kAudioAggregateDeviceNameKey: "OSS_Diag_Route",
    kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceIsPrivateKey: 1,
    kAudioAggregateDeviceTapListKey: [subTapDict]
]

var aggDeviceID = AudioDeviceID(kAudioObjectUnknown)
let aggStatus = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggDeviceID)
guard aggStatus == noErr else {
    print("  ❌ CreateAggregateDevice failed: OSStatus \(aggStatus)")
    AudioHardwareDestroyProcessTap(tapID)
    exit(1)
}
print("  ✓ Created aggregate device ID \(aggDeviceID)")

// Check aggregate device format
var aggSRAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var aggSR: Float64 = 0
var aggSRSize = UInt32(MemoryLayout<Float64>.size)
AudioObjectGetPropertyData(aggDeviceID, &aggSRAddr, 0, nil, &aggSRSize, &aggSR)
print("  Aggregate sample rate: \(Int(aggSR)) Hz")

// Check aggregate input channels
var aggChanAddr = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyStreamConfiguration,
    mScope: kAudioDevicePropertyScopeInput,
    mElement: kAudioObjectPropertyElementMain
)
var aggChanSize: UInt32 = 0
if AudioObjectGetPropertyDataSize(aggDeviceID, &aggChanAddr, 0, nil, &aggChanSize) == noErr {
    let bufPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
    defer { bufPtr.deallocate() }
    if AudioObjectGetPropertyData(aggDeviceID, &aggChanAddr, 0, nil, &aggChanSize, bufPtr) == noErr {
        let bufList = UnsafeMutableAudioBufferListPointer(bufPtr)
        var totalCh: UInt32 = 0
        for b in bufList { totalCh += b.mNumberChannels }
        print("  Aggregate input channels: \(totalCh)")
    }
}

Thread.sleep(forTimeInterval: 0.5)

// MARK: - Step 6: Create capture AUHAL
print("\n[STEP 6] Creating capture AudioUnit...")

var captureDesc = AudioComponentDescription(
    componentType: kAudioUnitType_Output,
    componentSubType: kAudioUnitSubType_HALOutput,
    componentManufacturer: kAudioUnitManufacturer_Apple,
    componentFlags: 0, componentFlagsMask: 0
)
guard let component = AudioComponentFindNext(nil, &captureDesc) else {
    print("  ❌ AudioComponent not found")
    AudioHardwareDestroyAggregateDevice(aggDeviceID)
    AudioHardwareDestroyProcessTap(tapID)
    exit(1)
}

var optCaptureUnit: AudioUnit?
var status = AudioComponentInstanceNew(component, &optCaptureUnit)
guard status == noErr, let captureUnit = optCaptureUnit else {
    print("  ❌ AudioComponentInstanceNew failed: \(status)")
    AudioHardwareDestroyAggregateDevice(aggDeviceID)
    AudioHardwareDestroyProcessTap(tapID)
    exit(1)
}

var one: UInt32 = 1
var zero: UInt32 = 0
AudioUnitSetProperty(captureUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, UInt32(MemoryLayout<UInt32>.size))
AudioUnitSetProperty(captureUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, UInt32(MemoryLayout<UInt32>.size))

var devID = aggDeviceID
status = AudioUnitSetProperty(captureUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &devID, UInt32(MemoryLayout<AudioDeviceID>.size))
print("  Set device to aggregate: OSStatus \(status)")

var captureASBD = AudioStreamBasicDescription()
var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
AudioUnitGetProperty(captureUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &captureASBD, &asbdSize)
let captureSR = captureASBD.mSampleRate > 0 ? captureASBD.mSampleRate : 48000
let captureCh = captureASBD.mChannelsPerFrame > 0 ? captureASBD.mChannelsPerFrame : 2
print("  Capture format: \(captureCh)ch, \(Int(captureSR))Hz")

let captureFormat = AVAudioFormat(standardFormatWithSampleRate: captureSR, channels: AVAudioChannelCount(captureCh))!
var outASBD = captureFormat.streamDescription.pointee
AudioUnitSetProperty(captureUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &outASBD, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
print("  ✓ Capture AUHAL configured")

// MARK: - Step 7: Create playback engine
print("\n[STEP 7] Creating playback engine on speaker...")

let engine = AVAudioEngine()
let playerNode = AVAudioPlayerNode()
engine.attach(playerNode)

// Disable input on output AUHAL to prevent Bluetooth HFP switch
if let outputAU = engine.outputNode.audioUnit {
    AudioUnitSetProperty(outputAU, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &zero, UInt32(MemoryLayout<UInt32>.size))
}

do {
    try engine.outputNode.auAudioUnit.setDeviceID(speaker.id)
    print("  ✓ Output device set to: \(speaker.name)")
} catch {
    print("  ❌ Failed to set output device: \(error)")
    AudioComponentInstanceDispose(captureUnit)
    AudioHardwareDestroyAggregateDevice(aggDeviceID)
    AudioHardwareDestroyProcessTap(tapID)
    exit(1)
}

let outputHWFormat = engine.outputNode.outputFormat(forBus: 0)
print("  Output HW format: \(outputHWFormat.channelCount)ch, \(Int(outputHWFormat.sampleRate))Hz")

let outputSR = outputHWFormat.sampleRate > 0 ? outputHWFormat.sampleRate : 48000
let outputCh = outputHWFormat.channelCount > 0 ? outputHWFormat.channelCount : 2
let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: outputSR, channels: AVAudioChannelCount(outputCh))!

engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)
engine.mainMixerNode.outputVolume = 1.0
print("  Mixer volume: \(engine.mainMixerNode.outputVolume)")

// Check if format conversion is needed
let needsConversion = abs(captureSR - outputSR) > 1.0 || captureCh != AVAudioChannelCount(outputCh)
var converter: AVAudioConverter? = nil
if needsConversion {
    converter = AVAudioConverter(from: captureFormat, to: playbackFormat)
    print("  ⚠️  Format conversion needed: \(captureCh)ch/\(Int(captureSR))Hz → \(outputCh)ch/\(Int(outputSR))Hz")
    if converter == nil {
        print("  ❌ Failed to create AVAudioConverter!")
    }
} else {
    print("  ✓ No format conversion needed")
}

// MARK: - Step 8: Set up render callback and start
print("\n[STEP 8] Setting up render callback...")

// Shared state for diagnostics
class DiagContext {
    let captureUnit: AudioUnit
    let playerNode: AVAudioPlayerNode
    let captureFormat: AVAudioFormat
    let playbackFormat: AVAudioFormat
    let converter: AVAudioConverter?
    var bufferCount: UInt64 = 0
    var totalFrames: UInt64 = 0
    var peakLevel: Float = 0
    var renderErrors: Int = 0
    var silentBuffers: Int = 0
    var scheduledBuffers: Int = 0

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

let context = DiagContext(
    captureUnit: captureUnit, playerNode: playerNode,
    captureFormat: captureFormat, playbackFormat: playbackFormat,
    converter: converter
)
let contextRetained = Unmanaged.passRetained(context)

var callbackStruct = AURenderCallbackStruct(
    inputProc: { (inRefCon, ioActionFlags, inTimeStamp, _, inNumberFrames, _) -> OSStatus in
        let ctx = Unmanaged<DiagContext>.fromOpaque(inRefCon).takeUnretainedValue()

        guard let buffer = AVAudioPCMBuffer(pcmFormat: ctx.captureFormat, frameCapacity: inNumberFrames) else { return noErr }
        buffer.frameLength = inNumberFrames

        let renderStatus = withUnsafeMutablePointer(to: &buffer.mutableAudioBufferList.pointee) { ablPtr in
            AudioUnitRender(ctx.captureUnit, ioActionFlags, inTimeStamp, 1, inNumberFrames, ablPtr)
        }
        guard renderStatus == noErr else {
            ctx.renderErrors += 1
            return noErr
        }

        ctx.bufferCount += 1
        ctx.totalFrames += UInt64(buffer.frameLength)

        // Measure peak level
        var peak: Float = 0
        if let cd = buffer.floatChannelData {
            for i in 0..<Int(buffer.frameLength) {
                let s = abs(cd[0][i])
                if s > peak { peak = s }
            }
        }
        if peak > ctx.peakLevel { ctx.peakLevel = peak }
        if peak < 0.0001 { ctx.silentBuffers += 1 }

        // Forward to player
        if let converter = ctx.converter {
            let ratio = ctx.playbackFormat.sampleRate / ctx.captureFormat.sampleRate
            let chRatio = Double(ctx.playbackFormat.channelCount) / Double(ctx.captureFormat.channelCount)
            let outCap = AVAudioFrameCount(Double(buffer.frameLength) * ratio * chRatio) + 1
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: ctx.playbackFormat, frameCapacity: outCap) else { return noErr }
            var err: NSError?
            var consumed = false
            converter.convert(to: outBuf, error: &err) { _, outStatus in
                if !consumed { consumed = true; outStatus.pointee = .haveData; return buffer }
                outStatus.pointee = .noDataNow; return nil
            }
            if err == nil && outBuf.frameLength > 0 {
                ctx.playerNode.scheduleBuffer(outBuf)
                ctx.scheduledBuffers += 1
            }
        } else {
            ctx.playerNode.scheduleBuffer(buffer)
            ctx.scheduledBuffers += 1
        }
        return noErr
    },
    inputProcRefCon: contextRetained.toOpaque()
)

status = AudioUnitSetProperty(captureUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
guard status == noErr else {
    print("  ❌ SetInputCallback failed: \(status)")
    exit(1)
}

status = AudioUnitInitialize(captureUnit)
guard status == noErr else {
    print("  ❌ AudioUnitInitialize failed: \(status)")
    exit(1)
}
print("  ✓ Capture AUHAL initialized")

// Start everything
engine.prepare()
do {
    try engine.start()
    print("  ✓ Playback engine started")
} catch {
    print("  ❌ Engine start failed: \(error)")
    AudioUnitUninitialize(captureUnit)
    AudioComponentInstanceDispose(captureUnit)
    AudioHardwareDestroyAggregateDevice(aggDeviceID)
    AudioHardwareDestroyProcessTap(tapID)
    exit(1)
}

playerNode.play()
print("  ✓ Player node started (isPlaying: \(playerNode.isPlaying))")

let startStatus = AudioOutputUnitStart(captureUnit)
guard startStatus == noErr else {
    print("  ❌ AudioOutputUnitStart failed: \(startStatus)")
    exit(1)
}
print("  ✓ Capture AUHAL started")

// MARK: - Step 9: Monitor audio flow
print("\n[STEP 9] Monitoring audio flow for 8 seconds...")
print("  ⚠️  Make sure Brave is playing audio NOW!\n")

for second in 1...8 {
    Thread.sleep(forTimeInterval: 1.0)

    let bufs = context.bufferCount
    let frames = context.totalFrames
    let peak = context.peakLevel
    let errors = context.renderErrors
    let silent = context.silentBuffers
    let scheduled = context.scheduledBuffers
    let engineRunning = engine.isRunning
    let playerPlaying = playerNode.isPlaying

    let peakDB = peak > 0 ? 20.0 * log10(Double(peak)) : -120.0

    print("  [\(second)s] bufs=\(bufs) frames=\(frames) peak=\(String(format: "%.4f", peak)) (\(String(format: "%.1f", peakDB))dB) silent=\(silent) errors=\(errors) scheduled=\(scheduled) engine=\(engineRunning) player=\(playerPlaying)")
}

// MARK: - Step 10: Diagnosis
print("\n" + ("=" * 60))
print("DIAGNOSIS")
print("=" * 60)

let totalBuffers = context.bufferCount
let totalSilent = context.silentBuffers
let totalErrors = context.renderErrors
let peakLevel = context.peakLevel

if totalBuffers == 0 {
    print("❌ NO AUDIO CAPTURED AT ALL")
    print("   - The render callback was never invoked")
    print("   - This means the aggregate device or AUHAL is not working")
    print("   - Check: Is the process tap correctly linked to Brave's audio?")
} else if totalErrors > 0 {
    print("⚠️  \(totalErrors) render errors occurred")
    print("   - AudioUnitRender failed on some buffers")
    print("   - Possible format mismatch or device issue")
} else if peakLevel < 0.0001 {
    print("⚠️  AUDIO CAPTURED BUT ALL SILENT (peak: \(peakLevel))")
    print("   - Brave may not be producing audio")
    print("   - Play a YouTube video or audio in Brave and re-run")
} else if peakLevel > 0.0001 {
    let scheduledPct = totalBuffers > 0 ? Double(context.scheduledBuffers) / Double(totalBuffers) * 100.0 : 0
    print("✓ AUDIO IS FLOWING (peak: \(String(format: "%.4f", peakLevel)), \(String(format: "%.1f%%", scheduledPct)) buffers scheduled)")

    if !engine.isRunning {
        print("❌ BUT ENGINE STOPPED!")
        print("   - The playback engine crashed after starting")
        print("   - Check for format mismatch between capture and playback")
    } else if !playerNode.isPlaying {
        print("❌ BUT PLAYER NODE STOPPED!")
        print("   - The player node stopped unexpectedly")
    } else {
        print("✓ Engine running, player playing")
        print("   → Audio SHOULD be coming from the speaker")
        print("   → If still silent, check macOS System Settings → Sound → Output")
        print("   → Also check if speaker volume is up in System Settings")
    }
}

// Check if the app code uses tapUUID vs tap UID property
print("\n--- Code Analysis ---")
print("App uses tapUUID.uuidString as kAudioSubTapUIDKey")
print("Actual tap UID from property: \(tapUIDString)")
print("tapUUID.uuidString:           \(tapUUID.uuidString)")
if tapUIDString == tapUUID.uuidString {
    print("✓ These match (tap UID is the UUID)")
} else {
    print("⚠️  MISMATCH — the app may be using the wrong UID for the sub-tap!")
    print("   The app should query kAudioTapPropertyUID after creating the tap")
}

// Cleanup
print("\nCleaning up...")
AudioOutputUnitStop(captureUnit)
AudioUnitUninitialize(captureUnit)
AudioComponentInstanceDispose(captureUnit)
contextRetained.release()
playerNode.stop()
engine.stop()
AudioHardwareDestroyAggregateDevice(aggDeviceID)
AudioHardwareDestroyProcessTap(tapID)
print("✓ Done")

func *(lhs: String, rhs: Int) -> String {
    return String(repeating: lhs, count: rhs)
}
