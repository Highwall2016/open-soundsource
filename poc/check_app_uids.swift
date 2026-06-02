import Foundation
import CoreAudio

let system = AudioObjectID(kAudioObjectSystemObject)
var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var dataSize: UInt32 = 0
AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &dataSize)
let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
var processIDs = [AudioObjectID](repeating: 0, count: count)
AudioObjectGetPropertyData(system, &addr, 0, nil, &dataSize, &processIDs)

for p in processIDs {
    var bAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var bValue: Unmanaged<CFString>?
    var bSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    if AudioObjectGetPropertyData(p, &bAddr, 0, nil, &bSize, &bValue) == noErr {
        let name = bValue?.takeRetainedValue() as String? ?? "Unknown"
        
        var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uidValue: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(p, &uidAddr, 0, nil, &uidSize, &uidValue) == noErr {
            let uid = uidValue?.takeRetainedValue() as String? ?? "Unknown"
            print("Device: \(name) - UID: \(uid)")
        }
    }
}
