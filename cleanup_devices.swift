import Foundation
import CoreAudio

let system = AudioObjectID(kAudioObjectSystemObject)
var addr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)

var size: UInt32 = 0
if AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr {
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
    if AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &deviceIDs) == noErr {
        for id in deviceIDs {
            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameValue: Unmanaged<CFString>? = nil
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            
            if AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &nameValue) == noErr {
                if let name = nameValue?.takeRetainedValue() as String? {
                    if name.hasPrefix("OSS_Route") {
                        print("Destroying aggregate device: \(name) (ID: \(id))")
                        AudioHardwareDestroyAggregateDevice(id)
                    }
                }
            }
        }
    }
}
print("Cleanup complete.")
