import Foundation
import CoreAudio

let bundleID = "com.google.Chrome"

let system = AudioObjectID(kAudioObjectSystemObject)
var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var dataSize: UInt32 = 0
AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &dataSize)
let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
var processIDs = [AudioObjectID](repeating: 0, count: count)
AudioObjectGetPropertyData(system, &addr, 0, nil, &dataSize, &processIDs)

for p in processIDs {
    var bAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var bValue: Unmanaged<CFString>?
    var bSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    if AudioObjectGetPropertyData(p, &bAddr, 0, nil, &bSize, &bValue) == noErr {
        if let b = bValue?.takeRetainedValue() as String?, b.hasPrefix(bundleID) {
            var isOutputAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var isOutput: UInt32 = 0
            var boolSize = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(p, &isOutputAddr, 0, nil, &boolSize, &isOutput)
            print("Chrome Process \(p) isRunningOutput: \(isOutput)")
        }
    }
}
