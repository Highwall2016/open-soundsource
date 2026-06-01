import CoreAudio
import AppKit

let system = AudioObjectID(kAudioObjectSystemObject)
var addr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyProcessObjectList,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)

var dataSize: UInt32 = 0
if AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &dataSize) == noErr {
    let processCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
    var processIDs = [AudioObjectID](repeating: 0, count: processCount)
    AudioObjectGetPropertyData(system, &addr, 0, nil, &dataSize, &processIDs)

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
            print("PID: \(p), Bundle: \(app?.bundleIdentifier ?? "nil"), Name: \(app?.localizedName ?? "nil")")
        }
    }
}
