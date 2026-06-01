#!/usr/bin/env swift
/// Minimal test: capture app audio via process tap, play it to a chosen output device.
/// Uses TWO AVAudioEngines: one for capture (tap aggregate), one for playback (target device).
/// Usage: swift Scripts/test_two_engine.swift <pid>

import CoreAudio
import AVFoundation
import AppKit
import Foundation

guard CommandLine.arguments.count >= 3, let pid = Int32(CommandLine.arguments[1]), let devIdx = Int(CommandLine.arguments[2]) else {
    print("Usage: swift Scripts/test_two_engine.swift <pid> <device_index>")
    exit(1)
}

// ── List output devices ──
func listOutputDevices() -> [(id: AudioDeviceID, name: String, uid: String)] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    var devices: [(id: AudioDeviceID, name: String, uid: String)] = []
    for id in ids {
        var chanAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var chanSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &chanAddr, 0, nil, &chanSize) == noErr, chanSize > 0 else { continue }
        let bufPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { bufPtr.deallocate() }
        guard AudioObjectGetPropertyData(id, &chanAddr, 0, nil, &chanSize, bufPtr) == noErr else { continue }
        var totalCh: UInt32 = 0
        for b in UnsafeMutableAudioBufferListPointer(bufPtr) { totalCh += b.mNumberChannels }
        guard totalCh > 0 else { continue }
        var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var nameVal: Unmanaged<CFString>? = nil; var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &nameVal) == noErr, let name = nameVal?.takeRetainedValue() as String? else { continue }
        var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uidVal: Unmanaged<CFString>? = nil; var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, &uidVal) == noErr, let uid = uidVal?.takeRetainedValue() as String? else { continue }
        if name.hasPrefix("OSS") { continue }
        devices.append((id: id, name: name, uid: uid))
    }
    return devices
}

let devices = listOutputDevices()
print("\nOutput devices:")
for (i, d) in devices.enumerated() { print("  [\(i)] \(d.name) (ID:\(d.id))") }
guard devIdx >= 0, devIdx < devices.count else { print("Invalid device index \(devIdx)"); exit(1) }
let targetDevice = devices[devIdx]
print("→ \(targetDevice.name)\n")

// ── Find process objects ──
func getProcessObjects(for bundleID: String) -> [AudioObjectID] {
    let prefix = bundleID + "."
    let system = AudioObjectID(kAudioObjectSystemObject)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &dataSize) == noErr else { return [] }
    let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    AudioObjectGetPropertyData(system, &addr, 0, nil, &dataSize, &ids)
    var matched: [AudioObjectID] = []
    for id in ids {
        var bidAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var bidVal: Unmanaged<CFString>? = nil; var bidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(id, &bidAddr, 0, nil, &bidSize, &bidVal) == noErr, let bid = bidVal?.takeRetainedValue() as String? {
            if bid == bundleID || bid.hasPrefix(prefix) { matched.append(id) }
        }
    }
    return matched
}

let bundleID: String
if let app = NSRunningApplication(processIdentifier: pid), let bid = app.bundleIdentifier {
    bundleID = bid
} else {
    // Try to find bundle ID from all running apps matching PID
    let apps = NSWorkspace.shared.runningApplications
    if let app = apps.first(where: { $0.processIdentifier == pid }), let bid = app.bundleIdentifier {
        bundleID = bid
    } else {
        print("ERROR: Cannot find bundle ID for PID \(pid)")
        print("Running apps:")
        for a in apps where a.activationPolicy == .regular {
            print("  PID \(a.processIdentifier): \(a.bundleIdentifier ?? "?")")
        }
        exit(1)
    }
}
print("PID \(pid), bundle: \(bundleID)")
let processObjIDs = getProcessObjects(for: bundleID)
guard !processObjIDs.isEmpty else { print("ERROR: No process objects"); exit(1) }
print("Found \(processObjIDs.count) process objects")

// ── Step 1: Create process tap ──
let tapUUID = UUID()
let desc = CATapDescription(stereoMixdownOfProcesses: processObjIDs)
desc.uuid = tapUUID
desc.isPrivate = false
desc.muteBehavior = .unmuted  // Keep original audio for testing

var tapID = AudioObjectID(kAudioObjectUnknown)
guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr else { print("ERROR: tap creation failed"); exit(1) }
print("✓ Process tap \(tapID)")

// ── Step 2: Create tap-only aggregate (input source) ──
let subTapDict: [String: Any] = [kAudioSubTapUIDKey: tapUUID.uuidString, kAudioSubTapDriftCompensationKey: false]
let aggDesc: [String: Any] = [
    kAudioAggregateDeviceNameKey: "OSS_Test_Capture",
    kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceIsPrivateKey: 1,
    kAudioAggregateDeviceTapListKey: [subTapDict]
]
var aggDeviceID = AudioDeviceID(kAudioObjectUnknown)
guard AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggDeviceID) == noErr else {
    print("ERROR: aggregate creation failed"); AudioHardwareDestroyProcessTap(tapID); exit(1)
}
print("✓ Tap aggregate device \(aggDeviceID)")
Thread.sleep(forTimeInterval: 0.5)

// ── Step 3: Query sample rate ──
var sampleRate: Float64 = 0
var srSize = UInt32(MemoryLayout<Float64>.size)
var srAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
if AudioObjectGetPropertyData(aggDeviceID, &srAddr, 0, nil, &srSize, &sampleRate) != noErr || sampleRate <= 0 { sampleRate = 48000 }
print("✓ Sample rate: \(Int(sampleRate)) Hz")

// ── Step 4: Capture engine — reads from tap aggregate ──
let captureEngine = AVAudioEngine()
guard let captureAU = captureEngine.inputNode.audioUnit else { print("ERROR: no input AU"); exit(1) }
var capDevID = aggDeviceID
let capStatus = AudioUnitSetProperty(captureAU, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &capDevID, UInt32(MemoryLayout<AudioDeviceID>.size))
guard capStatus == noErr else { print("ERROR: set capture device failed: \(capStatus)"); exit(1) }

let captureFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
print("✓ Capture format: \(captureFormat)")

// ── Step 5: Playback engine — writes to target device ──
let playbackEngine = AVAudioEngine()
let playerNode = AVAudioPlayerNode()
playbackEngine.attach(playerNode)

// Set output device on playback engine
do {
    try playbackEngine.outputNode.auAudioUnit.setDeviceID(targetDevice.id)
} catch {
    print("ERROR: set playback device failed: \(error)"); exit(1)
}

// Connect player -> output
playbackEngine.connect(playerNode, to: playbackEngine.mainMixerNode, format: captureFormat)
playbackEngine.mainMixerNode.outputVolume = 1.0

// ── Step 6: Install tap on capture engine's inputNode to forward audio ──
var bufferCount = 0
var maxRMS: Float = 0
captureEngine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: captureFormat) { buffer, _ in
    // Measure RMS
    if let data = buffer.floatChannelData?[0] {
        var sum: Float = 0
        let count = Int(buffer.frameLength)
        for i in 0..<count { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(max(count, 1)))
        if rms > maxRMS { maxRMS = rms }
    }
    bufferCount += 1
    playerNode.scheduleBuffer(buffer)
}

// ── Step 7: Start both engines ──
playbackEngine.prepare()
do {
    try playbackEngine.start()
    print("✓ Playback engine started, running: \(playbackEngine.isRunning)")
} catch {
    print("ERROR: playback engine start: \(error)"); exit(1)
}

playerNode.play()
print("✓ Player node playing")

captureEngine.prepare()
do {
    try captureEngine.start()
    print("✓ Capture engine started, running: \(captureEngine.isRunning)")
} catch {
    print("ERROR: capture engine start: \(error)"); exit(1)
}

Thread.sleep(forTimeInterval: 0.5)
print("\n✓ Both engines running. Capture: \(captureEngine.isRunning), Playback: \(playbackEngine.isRunning)")
print("🎧 Routing audio from PID \(pid) to \(targetDevice.name)")
print("   Will run for 10 seconds...\n")

// ── Monitor ──
var elapsed = 0
let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
    elapsed += 2
    print("  [\(elapsed)s] capture:\(captureEngine.isRunning) playback:\(playbackEngine.isRunning) player:\(playerNode.isPlaying) buffers:\(bufferCount) maxRMS:\(String(format: "%.4f", maxRMS))")
}
RunLoop.main.add(timer, forMode: .common)

DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
    timer.invalidate()
    captureEngine.inputNode.removeTap(onBus: 0)
    captureEngine.stop()
    playerNode.stop()
    playbackEngine.stop()
    AudioHardwareDestroyAggregateDevice(aggDeviceID)
    AudioHardwareDestroyProcessTap(tapID)
    print("✓ Cleaned up after 10s")
    exit(0)
}
RunLoop.main.run()
