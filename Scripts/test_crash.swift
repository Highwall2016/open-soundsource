import Foundation
import CoreAudio
import AVFAudio
import AppKit

// Run the core components of AudioManager to trigger the crash
let engine = AVAudioEngine()
let inputNode = engine.inputNode
let outputNode = engine.outputNode

// Pick an arbitrary output device
var addr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
var defaultOutput: AudioDeviceID = 0
var size = UInt32(MemoryLayout<AudioDeviceID>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &defaultOutput)

AudioUnitSetProperty(outputNode.audioUnit!,
                     kAudioOutputUnitProperty_CurrentDevice,
                     kAudioUnitScope_Global,
                     0,
                     &defaultOutput,
                     size)

print("Starting to connect...")
let format = inputNode.inputFormat(forBus: 0)
print("Input format: \(format)")

engine.connect(inputNode, to: engine.mainMixerNode, format: format)
print("Connected. Preparing...")

engine.prepare()
do {
    try engine.start()
    print("Started!")
} catch {
    print("Error: \(error)")
}
