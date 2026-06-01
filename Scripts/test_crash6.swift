import Foundation
import CoreAudio
import AVFAudio
import AppKit

let chromePid = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.google.Chrome" })?.processIdentifier ?? 0
print("Chrome PID: \(chromePid)")

var objAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var size: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &objAddr, 0, nil, &size)
let count = Int(size) / MemoryLayout<AudioObjectID>.size
var ids = [AudioObjectID](repeating: 0, count: count)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &objAddr, 0, nil, &size, &ids)

var processObjectID: AudioObjectID? = nil
for id in ids {
    var pidAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var procPid: UInt32 = 0
    var pidSize = UInt32(MemoryLayout<UInt32>.size)
    if AudioObjectGetPropertyData(id, &pidAddr, 0, nil, &pidSize, &procPid) == noErr {
        if pid_t(procPid) == chromePid { processObjectID = id }
    }
}

print("Chrome Process Object ID: \(String(describing: processObjectID))")

if let processObjectID = processObjectID {
    let desc = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
    desc.isPrivate = true
    var tapID = AudioObjectID(kAudioObjectUnknown)
    let status = AudioHardwareCreateProcessTap(desc, &tapID)
    print("Tap ID: \(tapID), status: \(status)")

    let engine = AVAudioEngine()
    
    var enableIO: UInt32 = 1
    AudioUnitSetProperty(engine.inputNode.audioUnit!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableIO, UInt32(MemoryLayout<UInt32>.size))
    
    var inputDeviceID = tapID
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioUnitSetProperty(engine.inputNode.audioUnit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &inputDeviceID, size)

    let format = engine.inputNode.inputFormat(forBus: 0)
    print("Format: \(format)")
    
    if format.channelCount > 0 {
        engine.connect(engine.inputNode, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            print("Started!")
        } catch {
            print("Error: \(error)")
        }
    } else {
        print("Invalid format channel count!")
    }
}
