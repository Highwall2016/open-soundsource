import Foundation
import CoreAudio
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
    
    let ioProc: AudioDeviceIOProc = { (deviceID, inNow, inInputData, inInputTime, outOutputData, inOutputTime, inClientData) -> OSStatus in
        print("Got audio data! Buffers: \(inInputData.pointee.mNumberBuffers)")
        return noErr
    }
    
    var procID: AudioDeviceIOProcID? = nil
    let err = AudioDeviceCreateIOProcID(tapID, ioProc, nil, &procID)
    print("Create IO Proc: \(err)")
    if err == noErr, let procID = procID {
        AudioDeviceStart(tapID, procID)
        print("Started tap device!")
        Thread.sleep(forTimeInterval: 2.0)
        AudioDeviceStop(tapID, procID)
    }
}
