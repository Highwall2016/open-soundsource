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
    desc.isPrivate = true
    var tapID = AudioObjectID(kAudioObjectUnknown)
    AudioHardwareCreateProcessTap(desc, &tapID)
    
    var formatAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    var streamFormat = AudioStreamBasicDescription()
    var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let err = AudioObjectGetPropertyData(tapID, &formatAddr, 0, nil, &fmtSize, &streamFormat)
    print("Error: \(err)")
    print("Format sample rate: \(streamFormat.mSampleRate), channels: \(streamFormat.mChannelsPerFrame)")
}
