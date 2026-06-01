import Foundation
import CoreAudio
import AVFoundation

let pid = Int32(CommandLine.arguments.count > 1 ? Int32(CommandLine.arguments[1])! : ProcessInfo.processInfo.processIdentifier)
let outputDeviceUID = "BuiltInSpeakerDevice" // We'll change this to the target device later

func getProcessObjectIDs(for pid: pid_t) -> [AudioObjectID] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &dataSize)
    let processCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
    var processIDs = [AudioObjectID](repeating: 0, count: processCount)
    AudioObjectGetPropertyData(system, &addr, 0, nil, &dataSize, &processIDs)
    
    var matched: [AudioObjectID] = []
    for processID in processIDs {
        var pidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sz = UInt32(MemoryLayout<pid_t>.size)
        var p: pid_t = 0
        if AudioObjectGetPropertyData(processID, &pidAddr, 0, nil, &sz, &p) == noErr {
            if p == pid {
                matched.append(processID)
            }
        }
    }
    return matched
}

let pids = getProcessObjectIDs(for: pid)
print("PIDs to tap: \(pids)")
if pids.isEmpty { exit(1) }

let tapUUID = UUID()
let desc = CATapDescription(stereoMixdownOfProcesses: pids)
desc.uuid = tapUUID
desc.isPrivate = false
desc.muteBehavior = .muted

var tapID = AudioObjectID(kAudioObjectUnknown)
let tapStatus = AudioHardwareCreateProcessTap(desc, &tapID)
print("Tap status: \(tapStatus) tapID: \(tapID)")

let tapConfig: [String: Any] = [kAudioSubTapUIDKey: tapUUID.uuidString]
let aggDict: [String: Any] = [
    kAudioAggregateDeviceNameKey: "OSS_Route_Test",
    kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceTapListKey: [tapConfig],
    kAudioAggregateDeviceIsPrivateKey: 0
]

var aggregateDeviceID: AudioObjectID = 0
let aggStatus = AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &aggregateDeviceID)
print("Agg status: \(aggStatus) aggID: \(aggregateDeviceID)")

Thread.sleep(forTimeInterval: 0.5)

let engine = AVAudioEngine()
do {
    try engine.inputNode.auAudioUnit.setDeviceID(aggregateDeviceID)
    try engine.outputNode.auAudioUnit.setDeviceID(aggregateDeviceID) // Usually needs output to start input?
    let format = engine.inputNode.outputFormat(forBus: 0)
    print("Input format: \(format), channels: \(format.channelCount)")
} catch {
    print("Engine error: \(error)")
}
