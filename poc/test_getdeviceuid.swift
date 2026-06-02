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

var addr = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyDeviceUID,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
var uidValue: Unmanaged<CFString>? = nil
var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
let status = AudioObjectGetPropertyData(defID, &addr, 0, nil, &size, &uidValue)
let uid = uidValue?.takeRetainedValue() as String?
print("System Default Output Device UID: \(uid ?? "nil") (status: \(status))")
