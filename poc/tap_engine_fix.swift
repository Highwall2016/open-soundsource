import Foundation
import CoreAudio
import AVFoundation

let bundleID = "com.google.Chrome"

let system = AudioObjectID(kAudioObjectSystemObject)
var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var dataSize: UInt32 = 0
AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &dataSize)
let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
var processIDs = [AudioObjectID](repeating: 0, count: count)
AudioObjectGetPropertyData(system, &addr, 0, nil, &dataSize, &processIDs)

var matched: [AudioObjectID] = []
for p in processIDs {
    var bAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var bValue: Unmanaged<CFString>?
    var bSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    if AudioObjectGetPropertyData(p, &bAddr, 0, nil, &bSize, &bValue) == noErr {
        if let b = bValue?.takeRetainedValue() as String?, b.hasPrefix(bundleID) {
            matched.append(p)
        }
    }
}
if matched.isEmpty { exit(0) }

let desc = CATapDescription(stereoMixdownOfProcesses: matched)
desc.uuid = UUID()
desc.isPrivate = false
desc.muteBehavior = .muted

var tapID = AudioObjectID(kAudioObjectUnknown)
AudioHardwareCreateProcessTap(desc, &tapID)

var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var uidValue: Unmanaged<CFString>?
var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
AudioObjectGetPropertyData(tapID, &uidAddr, 0, nil, &uidSize, &uidValue)
let actualUID = uidValue?.takeRetainedValue() as String? ?? desc.uuid.uuidString

var defAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var defID = AudioObjectID(kAudioObjectUnknown)
var defSize = UInt32(MemoryLayout<AudioObjectID>.size)
AudioObjectGetPropertyData(system, &defAddr, 0, nil, &defSize, &defID)
var duidAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var duidValue: Unmanaged<CFString>?
var duidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
AudioObjectGetPropertyData(defID, &duidAddr, 0, nil, &duidSize, &duidValue)
let defUID = duidValue?.takeRetainedValue() as String? ?? ""

let aggDict: [String: Any] = [
    kAudioAggregateDeviceNameKey: "TestTapEngineFix",
    kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceIsPrivateKey: 1,
    kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: actualUID, kAudioSubTapDriftCompensationKey: false]],
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: defUID]],
    kAudioAggregateDeviceMainSubDeviceKey: defUID
]
var aggID: AudioObjectID = 0
AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &aggID)

var compDesc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
let comp = AudioComponentFindNext(nil, &compDesc)!
var unit: AudioUnit?
AudioComponentInstanceNew(comp, &unit)

var one: UInt32 = 1, zero: UInt32 = 0
AudioUnitSetProperty(unit!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4)
AudioUnitSetProperty(unit!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, 4)
AudioUnitSetProperty(unit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &aggID, 4)

var captureFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
var asbd = captureFormat.streamDescription.pointee
AudioUnitSetProperty(unit!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

let engine = AVAudioEngine()
let playerNode = AVAudioPlayerNode()

// Try to set device ID safely
try? engine.outputNode.auAudioUnit.setDeviceID(defID)
let outFormat = engine.outputNode.outputFormat(forBus: 0)
let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: outFormat.sampleRate, channels: outFormat.channelCount)!

engine.attach(playerNode)
// Connect player to mixer using playback format, then mixer to output using outFormat?
// Actually just connect player to mainMixer. AVAudioEngine handles mainMixer -> output automatically!
engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)

var converter: AVAudioConverter? = nil
if playbackFormat.sampleRate != captureFormat.sampleRate {
    converter = AVAudioConverter(from: captureFormat, to: playbackFormat)
}

class Ctx {
    var maxPeak: Float32 = 0
    var buffers: Int = 0
}
var rCtx = (unit: unit!, player: playerNode, capFormat: captureFormat, playFormat: playbackFormat, conv: converter, maxPeak: Float32(0), buffers: 0)

let cb: AURenderCallback = { (inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData) -> OSStatus in
    let ptr = inRefCon.bindMemory(to: (unit: AudioUnit, player: AVAudioPlayerNode, capFormat: AVAudioFormat, playFormat: AVAudioFormat, conv: AVAudioConverter?, maxPeak: Float32, buffers: Int).self, capacity: 1)
    ptr.pointee.buffers += 1
    
    let buffer = AVAudioPCMBuffer(pcmFormat: ptr.pointee.capFormat, frameCapacity: inNumberFrames)!
    buffer.frameLength = inNumberFrames
    
    let status = withUnsafeMutablePointer(to: &buffer.mutableAudioBufferList.pointee) { ablPtr in
        AudioUnitRender(ptr.pointee.unit, ioActionFlags, inTimeStamp, 1, inNumberFrames, ablPtr)
    }
    
    if status == noErr {
        if let cd = buffer.floatChannelData {
            for i in 0..<Int(inNumberFrames * 2) {
                let s = abs(cd[0][i])
                if s > ptr.pointee.maxPeak { ptr.pointee.maxPeak = s }
            }
        }
    }
    return noErr
}

var cbStruct = AURenderCallbackStruct(inputProc: cb, inputProcRefCon: &rCtx)
AudioUnitSetProperty(unit!, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cbStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

try? engine.start()
playerNode.play()

AudioUnitInitialize(unit!)
AudioOutputUnitStart(unit!)

for i in 1...3 {
    Thread.sleep(forTimeInterval: 1.0)
    print("Sec \(i): peak = \(rCtx.maxPeak), total buffers = \(rCtx.buffers)")
    rCtx.maxPeak = 0
}

AudioOutputUnitStop(unit!)
playerNode.stop()
engine.stop()
AudioHardwareDestroyAggregateDevice(aggID)
AudioHardwareDestroyProcessTap(tapID)
