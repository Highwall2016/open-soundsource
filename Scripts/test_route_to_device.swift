#!/usr/bin/env swift
/// Test routing audio from an app to a specific output device via process tap + aggregate device.
/// Usage: swift Scripts/test_route_to_device.swift <pid>
/// It will list output devices and let you pick one.

import CoreAudio
import AVFoundation
import AppKit
import Foundation

guard CommandLine.arguments.count >= 2, let pid = Int32(CommandLine.arguments[1]) else {
    print("Usage: swift Scripts/test_route_to_device.swift <pid>")
    exit(1)
}

// -- List output devices --
func listOutputDevices() -> [(id: AudioDeviceID, name: String, uid: String)] {
    let system = AudioObjectID(kAudioObjectSystemObject)
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

    var devices: [(id: AudioDeviceID, name: String, uid: String)] = []
    for id in ids {
        // Check output channels
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

        // Get name
        var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var nameVal: Unmanaged<CFString>? = nil
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &nameVal) == noErr,
              let name = nameVal?.takeRetainedValue() as String? else { continue }

        // Get UID
        var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uidVal: Unmanaged<CFString>? = nil
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, &uidVal) == noErr,
              let uid = uidVal?.takeRetainedValue() as String? else { continue }

        if name.hasPrefix("OSS") { continue }
        devices.append((id: id, name: name, uid: uid))
    }
    return devices
}

let devices = listOutputDevices()
print("\nOutput devices:")
for (i, d) in devices.enumerated() {
    print("  [\(i)] \(d.name) (ID: \(d.id), UID: \(d.uid))")
}
print("\nSelect device number: ", terminator: "")
guard let line = readLine(), let idx = Int(line), idx >= 0, idx < devices.count else {
    print("Invalid selection")
    exit(1)
}
let targetDevice = devices[idx]
print("Selected: \(targetDevice.name)")

// -- Get process objects --
func getProcessObjectIDs(for pid: pid_t) -> [AudioObjectID] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &dataSize) == noErr else { return [] }
    let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    AudioObjectGetPropertyData(system, &addr, 0, nil, &dataSize, &ids)

    var matched: [AudioObjectID] = []
    for id in ids {
        var pidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var procPid: UInt32 = 0
        var pidSize = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(id, &pidAddr, 0, nil, &pidSize, &procPid) == noErr {
            if pid_t(procPid) == pid {
                matched.append(id)
            }
        }
    }
    return matched
}

// -- Also find by bundle ID --
let app = NSRunningApplication(processIdentifier: pid)
let bundleID = app?.bundleIdentifier ?? ""
print("PID \(pid), bundle: \(bundleID)")

func getProcessObjectIDsByBundle(_ bundleID: String) -> [AudioObjectID] {
    guard !bundleID.isEmpty else { return [] }
    let prefix = bundleID + "."
    let system = AudioObjectID(kAudioObjectSystemObject)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &dataSize) == noErr else { return [] }
    let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    AudioObjectGetPropertyData(system, &addr, 0, nil, &dataSize, &ids)

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
                if bid == bundleID || bid.hasPrefix(prefix) {
                    matched.append(id)
                }
            }
        }
    }
    return matched
}

var processObjIDs = getProcessObjectIDsByBundle(bundleID)
if processObjIDs.isEmpty {
    processObjIDs = getProcessObjectIDs(for: pid)
}
print("Found \(processObjIDs.count) process objects: \(processObjIDs)")
guard !processObjIDs.isEmpty else {
    print("ERROR: No process objects found")
    exit(1)
}

// -- Create process tap --
let tapUUID = UUID()
let desc = CATapDescription(stereoMixdownOfProcesses: processObjIDs)
desc.uuid = tapUUID
desc.isPrivate = false
desc.muteBehavior = .unmuted  // Keep original output too for testing

var tapID = AudioObjectID(kAudioObjectUnknown)
let tapStatus = AudioHardwareCreateProcessTap(desc, &tapID)
guard tapStatus == noErr else {
    print("ERROR: CreateProcessTap failed: \(tapStatus)")
    exit(1)
}
print("✓ Created process tap \(tapID)")

// -- Query tap UID --
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
    print("✓ Tap UID (from property): \(tapUIDString)")
} else {
    tapUIDString = tapUUID.uuidString
    print("⚠️ Could not query tap UID, using UUID: \(tapUIDString)")
}

// -- Create aggregate device (tap-only, like POC) --
let subTapDict: [String: Any] = [
    kAudioSubTapUIDKey: tapUIDString,
    kAudioSubTapDriftCompensationKey: false
]
let aggDesc: [String: Any] = [
    kAudioAggregateDeviceNameKey: "OSS_Test_Route",
    kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceIsPrivateKey: 1,
    kAudioAggregateDeviceTapListKey: [subTapDict]
]

var aggDeviceID = AudioDeviceID(kAudioObjectUnknown)
let aggStatus = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggDeviceID)
guard aggStatus == noErr else {
    print("ERROR: CreateAggregateDevice failed: \(aggStatus)")
    AudioHardwareDestroyProcessTap(tapID)
    exit(1)
}
print("✓ Created tap-only aggregate device \(aggDeviceID)")

Thread.sleep(forTimeInterval: 0.5)

// -- Query sample rate --
var sampleRate: Float64 = 0
var srSize = UInt32(MemoryLayout<Float64>.size)
var srAddr = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyNominalSampleRate,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
if AudioObjectGetPropertyData(aggDeviceID, &srAddr, 0, nil, &srSize, &sampleRate) == noErr {
    print("✓ Aggregate sample rate: \(Int(sampleRate)) Hz")
} else {
    sampleRate = 48000
    print("⚠️ Defaulting sample rate to 48000 Hz")
}

// -- Setup AVAudioEngine --
// Strategy: input from tap-only aggregate, output to target device
let engine = AVAudioEngine()

// Set INPUT to tap-only aggregate
let inputNode = engine.inputNode
guard let inputAU = inputNode.audioUnit else {
    print("ERROR: No audio unit on inputNode")
    exit(1)
}
var inputDevID = aggDeviceID
let inputStatus = AudioUnitSetProperty(
    inputAU,
    kAudioOutputUnitProperty_CurrentDevice,
    kAudioUnitScope_Global,
    0,
    &inputDevID,
    UInt32(MemoryLayout<AudioDeviceID>.size)
)
print("Set input device to aggregate: OSStatus \(inputStatus)")

// Set OUTPUT to target physical device
let outputNode = engine.outputNode
guard let outputAU = outputNode.audioUnit else {
    print("ERROR: No audio unit on outputNode")
    exit(1)
}
var outputDevID = targetDevice.id
let outputStatus = AudioUnitSetProperty(
    outputAU,
    kAudioOutputUnitProperty_CurrentDevice,
    kAudioUnitScope_Global,
    0,
    &outputDevID,
    UInt32(MemoryLayout<AudioDeviceID>.size)
)
print("Set output device to \(targetDevice.name): OSStatus \(outputStatus)")

// Check what format the input node reports
let hwInputFormat = inputNode.outputFormat(forBus: 0)
print("Input node HW format: \(hwInputFormat)")
print("  sampleRate: \(hwInputFormat.sampleRate)")
print("  channels: \(hwInputFormat.channelCount)")

let hwOutputFormat = outputNode.inputFormat(forBus: 0)
print("Output node HW format: \(hwOutputFormat)")
print("  sampleRate: \(hwOutputFormat.sampleRate)")
print("  channels: \(hwOutputFormat.channelCount)")

// Use a stereo format at the input's sample rate
let connectFormat = AVAudioFormat(standardFormatWithSampleRate: hwInputFormat.sampleRate, channels: 2)!
print("Connect format: \(connectFormat)")

engine.connect(engine.inputNode, to: engine.mainMixerNode, format: hwInputFormat)
engine.mainMixerNode.outputVolume = 1.0
engine.prepare()

do {
    try engine.start()
    print("✓ Engine started, running: \(engine.isRunning)")
} catch {
    print("ERROR: Engine start failed: \(error)")
    AudioHardwareDestroyAggregateDevice(aggDeviceID)
    AudioHardwareDestroyProcessTap(tapID)
    exit(1)
}

Thread.sleep(forTimeInterval: 0.3)
print("Engine still running: \(engine.isRunning)")

if !engine.isRunning {
    print("Engine stopped! Trying different approach...")
    // Try with nil format
    engine.disconnectNodeInput(engine.mainMixerNode)
    engine.connect(engine.inputNode, to: engine.mainMixerNode, format: nil)
    engine.prepare()
    do {
        try engine.start()
        Thread.sleep(forTimeInterval: 0.3)
        print("Retry engine running: \(engine.isRunning)")
    } catch {
        print("Retry failed: \(error)")
    }
}

// Monitor audio for 10 seconds
print("\n🎧 Monitoring audio... (press Enter to stop)\n")
var frameCounter = 0
let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
    frameCounter += 1
    if frameCounter % 20 == 0 { // Every 2 seconds
        print("  Engine running: \(engine.isRunning), mixer volume: \(engine.mainMixerNode.outputVolume)")
    }
}
RunLoop.main.add(timer, forMode: .common)

let stdinHandle = FileHandle.standardInput
stdinHandle.waitForDataInBackgroundAndNotify()
NotificationCenter.default.addObserver(forName: .NSFileHandleDataAvailable, object: stdinHandle, queue: .main) { _ in
    timer.invalidate()
    engine.stop()
    AudioHardwareDestroyAggregateDevice(aggDeviceID)
    AudioHardwareDestroyProcessTap(tapID)
    print("\n✓ Cleaned up")
    exit(0)
}

RunLoop.main.run()
