import Foundation
import CoreAudio

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

for processID in processIDs {
    var pidAddr = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyPID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var sz = UInt32(MemoryLayout<pid_t>.size)
    var p: pid_t = 0
    if AudioObjectGetPropertyData(processID, &pidAddr, 0, nil, &sz, &p) == noErr {
        var bundleIDAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var bundleIDValue: Unmanaged<CFString>? = nil
        var bundleIDSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(processID, &bundleIDAddr, 0, nil, &bundleIDSize, &bundleIDValue) == noErr {
            let bundleID = bundleIDValue?.takeRetainedValue() as String? ?? "N/A"
            print("PID \(p): CoreAudio BundleID: \(bundleID)")
        } else {
            print("PID \(p): NO CoreAudio BundleID")
        }
    }
}
