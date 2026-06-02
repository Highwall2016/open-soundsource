import Foundation
import CoreAudio

let system = AudioObjectID(kAudioObjectSystemObject)
var defAddr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
var defID = AudioObjectID(kAudioObjectUnknown)
var defSize = UInt32(MemoryLayout<AudioObjectID>.size)
AudioObjectGetPropertyData(system, &defAddr, 0, nil, &defSize, &defID)

var nameAddr = AudioObjectPropertyAddress(
    mSelector: kAudioObjectPropertyName,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
var nameValue: Unmanaged<CFString>? = nil
var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
AudioObjectGetPropertyData(defID, &nameAddr, 0, nil, &nameSize, &nameValue)
let name = nameValue?.takeRetainedValue() as String? ?? "Unknown"

print("Current System Default Output Device: \(name) (ID: \(defID))")
