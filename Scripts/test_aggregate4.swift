import Foundation
import CoreAudio
import AVFAudio
import AppKit

let chromePid = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.google.Chrome" })?.processIdentifier ?? 0
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
    if AudioObjectGetPropertyData(id, &pidAddr, 0, nil, &pidSize, &procPid) == noErr { if pid_t(procPid) == chromePid { processObjectID = id } }
}

if let processObjectID = processObjectID {
    let desc = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
    let tapUUID = UUID()
    desc.uuid = tapUUID
    desc.isPrivate = true
    var tapID = AudioObjectID(kAudioObjectUnknown)
    AudioHardwareCreateProcessTap(desc, &tapID)
    
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var defaultOutput: AudioDeviceID = 0
    var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &defaultOutput)
    
    var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var outUIDValue: Unmanaged<CFString>? = nil
    var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    AudioObjectGetPropertyData(defaultOutput, &uidAddr, 0, nil, &uidSize, &outUIDValue)
    let outUID = outUIDValue?.takeRetainedValue() as String?
    
    let tapUID = tapUUID.uuidString
    
    if let outUID = outUID {
        let aggregateDeviceDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OSS Aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceSubDeviceListKey: [tapUID, outUID],
            kAudioAggregateDeviceMasterSubDeviceKey: outUID
        ]
        var aggregateDeviceID: AudioObjectID = 0
        let err = AudioHardwareCreateAggregateDevice(aggregateDeviceDict as CFDictionary, &aggregateDeviceID)
        
        if err == noErr {
            let engine = AVAudioEngine()
            var inputDeviceID = aggregateDeviceID
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            
            // Enable IO on input
            var enableIO: UInt32 = 1
            AudioUnitSetProperty(engine.inputNode.audioUnit!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableIO, UInt32(MemoryLayout<UInt32>.size))
            AudioUnitSetProperty(engine.inputNode.audioUnit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &inputDeviceID, size)
            
            // Enable IO on output
            var enableOutIO: UInt32 = 1
            AudioUnitSetProperty(engine.outputNode.audioUnit!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enableOutIO, UInt32(MemoryLayout<UInt32>.size))
            AudioUnitSetProperty(engine.outputNode.audioUnit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &inputDeviceID, size)
            
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000.0, channels: 2)!
            engine.connect(engine.inputNode, to: engine.mainMixerNode, format: format)
            do {
                engine.prepare()
                try engine.start()
                print("Engine started successfully with Aggregate Device and explicit format!")
            } catch { print("Engine start error: \(error)") }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
    }
}
