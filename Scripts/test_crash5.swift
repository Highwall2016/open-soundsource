import Foundation
import CoreAudio
import AVFAudio

let desc = CATapDescription(stereoMixdownOfProcesses: [0])
desc.isPrivate = true
var tapID = AudioObjectID(kAudioObjectUnknown)
let status = AudioHardwareCreateProcessTap(desc, &tapID)
print("Tap ID: \(tapID), status: \(status)")

let engine = AVAudioEngine()
var inputDeviceID = tapID
var size = UInt32(MemoryLayout<AudioDeviceID>.size)
AudioUnitSetProperty(engine.inputNode.audioUnit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &inputDeviceID, size)

let format = AVAudioFormat(standardFormatWithSampleRate: 48000.0, channels: 2)
engine.connect(engine.inputNode, to: engine.mainMixerNode, format: format)

do {
    try engine.start()
    print("Started!")
} catch {
    print("Error: \(error)")
}
