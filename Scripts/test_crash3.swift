import Foundation
import CoreAudio
import AVFAudio

let engine = AVAudioEngine()
let inputNode = engine.inputNode
let outputNode = engine.outputNode

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

AudioUnitSetProperty(outputNode.audioUnit!,
                     kAudioOutputUnitProperty_CurrentDevice,
                     kAudioUnitScope_Global,
                     0,
                     &defaultOutput,
                     size)

let format = AVAudioFormat(standardFormatWithSampleRate: 48000.0, channels: 2)
engine.connect(inputNode, to: engine.mainMixerNode, format: format)
engine.prepare()
do {
    try engine.start()
    print("Started successfully!")
} catch {
    print("Error: \(error)")
}
