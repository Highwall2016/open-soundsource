#!/usr/bin/env swift
import Foundation
import CoreAudio

let system = AudioObjectID(kAudioObjectSystemObject)

// 1. Destroy orphaned aggregate devices
var devAddr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)

var size: UInt32 = 0
if AudioObjectGetPropertyDataSize(system, &devAddr, 0, nil, &size) == noErr {
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
    if AudioObjectGetPropertyData(system, &devAddr, 0, nil, &size, &deviceIDs) == noErr {
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
                    if name.hasPrefix("OSS_Route") || name.hasPrefix("OSS_") {
                        print("Destroying aggregate device: \(name) (ID: \(id))")
                        AudioHardwareDestroyAggregateDevice(id)
                    }
                }
            }
        }
    }
}

// 2. Destroy orphaned process taps
var tapAddr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyTapList,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)

var tapSize: UInt32 = 0
if AudioObjectGetPropertyDataSize(system, &tapAddr, 0, nil, &tapSize) == noErr, tapSize > 0 {
    let tapCount = Int(tapSize) / MemoryLayout<AudioObjectID>.size
    var tapIDs = [AudioObjectID](repeating: 0, count: tapCount)
    if AudioObjectGetPropertyData(system, &tapAddr, 0, nil, &tapSize, &tapIDs) == noErr {
        print("Found \(tapCount) process tap(s)")
        for tapID in tapIDs {
            print("  Destroying process tap ID: \(tapID)")
            AudioHardwareDestroyProcessTap(tapID)
        }
    }
} else {
    print("No process taps found")
}

print("Full cleanup complete — Brave audio should be restored.")
