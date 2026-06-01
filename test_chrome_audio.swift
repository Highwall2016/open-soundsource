import Foundation
import CoreAudio
import AppKit

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

print("Found \(processCount) process objects")

for processID in processIDs {
    var pidAddr = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyPID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var sz = UInt32(MemoryLayout<pid_t>.size)
    var p: pid_t = 0
    if AudioObjectGetPropertyData(processID, &pidAddr, 0, nil, &sz, &p) == noErr {
        let app = NSRunningApplication(processIdentifier: p)
        let bundleID = app?.bundleIdentifier ?? "UNKNOWN"
        let name = app?.localizedName ?? "UNKNOWN"
        print("ProcessObjectID: \(processID), PID: \(p), BundleID: \(bundleID), Name: \(name)")
    }
}
