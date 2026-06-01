/// list-devices — enumerate all CoreAudio output devices on this Mac.
///
/// Usage:  swift run list-devices
///
/// No special entitlements required.

import CoreAudio
import Foundation

// ── CoreAudio HAL property helpers ──────────────────────────────────────────

func getPropertyString(
    _ objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope:    scope,
        mElement:  kAudioObjectPropertyElementMain
    )
    var value: CFString? = nil
    var size = UInt32(MemoryLayout<CFString?>.size)
    let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value)
    guard status == noErr, let result = value else { return nil }
    return result as String
}

func getPropertyUInt32(
    _ objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> UInt32? {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope:    scope,
        mElement:  kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value)
    return status == noErr ? value : nil
}

func getPropertyFloat64(
    _ objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> Float64? {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope:    scope,
        mElement:  kAudioObjectPropertyElementMain
    )
    var value: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value)
    return status == noErr ? value : nil
}

func getPropertyObjectIDs(
    _ objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope:    scope,
        mElement:  kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size) == noErr,
          size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

// ── Transport type label ─────────────────────────────────────────────────────

func transportLabel(_ type: UInt32) -> String {
    switch type {
    case kAudioDeviceTransportTypeBuiltIn:      return "Built-in"
    case kAudioDeviceTransportTypeUSB:          return "USB"
    case kAudioDeviceTransportTypeFireWire:     return "FireWire"
    case kAudioDeviceTransportTypeBluetooth:    return "Bluetooth"
    case kAudioDeviceTransportTypeBluetoothLE:  return "Bluetooth LE"
    case kAudioDeviceTransportTypeHDMI:         return "HDMI"
    case kAudioDeviceTransportTypeDisplayPort:  return "DisplayPort"
    case kAudioDeviceTransportTypeAirPlay:      return "AirPlay"
    case kAudioDeviceTransportTypeThunderbolt:  return "Thunderbolt"
    case kAudioDeviceTransportTypeVirtual:      return "Virtual"
    case kAudioDeviceTransportTypeAggregate:    return "Aggregate"
    case kAudioDeviceTransportTypeAVB:          return "AVB"
    default: return "Unknown (0x\(String(type, radix: 16)))"
    }
}

// ── Main ─────────────────────────────────────────────────────────────────────

let system = AudioObjectID(kAudioObjectSystemObject)

// Default output device
var defaultOutputID: AudioObjectID = kAudioObjectUnknown
do {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope:    kAudioObjectPropertyScopeGlobal,
        mElement:  kAudioObjectPropertyElementMain
    )
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &defaultOutputID)
}

let allDeviceIDs = getPropertyObjectIDs(system, selector: kAudioHardwarePropertyDevices)

print()
print("🔊 Audio Output Devices  (\(allDeviceIDs.count) total, showing output-capable)")
print(String(repeating: "─", count: 64))

var outputCount = 0

for deviceID in allDeviceIDs {
    // Only show devices that have output streams
    let outputStreams = getPropertyObjectIDs(
        deviceID,
        selector: kAudioDevicePropertyStreams,
        scope: kAudioObjectPropertyScopeOutput
    )
    guard !outputStreams.isEmpty else { continue }
    outputCount += 1

    let name         = getPropertyString(deviceID, selector: kAudioDevicePropertyDeviceNameCFString) ?? "<unknown>"
    let uid          = getPropertyString(deviceID, selector: kAudioDevicePropertyDeviceUID) ?? "<unknown>"
    let manufacturer = getPropertyString(deviceID, selector: kAudioDevicePropertyDeviceManufacturerCFString) ?? "—"
    let sampleRate   = getPropertyFloat64(deviceID, selector: kAudioDevicePropertyNominalSampleRate) ?? 0
    let transport    = getPropertyUInt32(deviceID, selector: kAudioDevicePropertyTransportType) ?? 0
    let isDefault    = (deviceID == defaultOutputID)

    // Sum channels across all output streams
    var channels: UInt32 = 0
    for streamID in outputStreams {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyPhysicalFormat,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(streamID, &addr, 0, nil, &size, &asbd)
        if status == noErr {
            channels += asbd.mChannelsPerFrame
        }
    }

    let marker = isDefault ? " ✓ default" : ""
    let arrow  = isDefault ? "▶" : " "
    print()
    print("\(arrow) \(name)\(marker)")
    print("   Manufacturer : \(manufacturer)")
    print("   UID          : \(uid)")
    print("   Transport    : \(transportLabel(transport))")
    print("   Sample Rate  : \(Int(sampleRate)) Hz")
    print("   Channels     : \(channels)")
    print("   Device ID    : \(deviceID)")
}

if outputCount == 0 {
    print("  (no output devices found)")
}
print()
