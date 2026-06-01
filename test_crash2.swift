import Foundation
import CoreAudio
import AVFAudio
import AppKit

let engine = AVAudioEngine()
let inputNode = engine.inputNode

// Try to set inputNode to a random valid device (like the default output just to see if format updates)
var addr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
var defaultOutput: AudioDeviceID = 0
var size = UInt32(MemoryLayout<AudioDeviceID>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &defaultOutput)

var inputDeviceID = defaultOutput
AudioUnitSetProperty(inputNode.audioUnit!,
                     kAudioOutputUnitProperty_CurrentDevice,
                     kAudioUnitScope_Global,
                     0,
                     &inputDeviceID,
                     size)

let format = inputNode.inputFormat(forBus: 0)
print("Input format after setting device: \(format)")
