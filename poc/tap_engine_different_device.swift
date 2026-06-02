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
    kAudioAggregateDeviceNameKey: "TestTapEngineFix2",
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

// Find another valid device that is NOT defID
var allDevsAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var allDevsSize: UInt32 = 0
AudioObjectGetPropertyDataSize(system, &allDevsAddr, 0, nil, &allDevsSize)
var allDevs = [AudioDeviceID](repeating: 0, count: Int(allDevsSize) / MemoryLayout<AudioDeviceID>.size)
AudioObjectGetPropertyData(system, &allDevsAddr, 0, nil, &allDevsSize, &allDevs)

var diffDevice: AudioDeviceID?
for dev in allDevs {
    var isOutputAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    var isOutSize: UInt32 = 0
    if AudioObjectGetPropertyDataSize(dev, &isOutputAddr, 0, nil, &isOutSize) == noErr && isOutSize > 0 {
        if dev != defID && dev != aggID {
            diffDevice = dev
            break
        }
    }
}

if let outDev = diffDevice {
    try? engine.outputNode.auAudioUnit.setDeviceID(outDev)
}

let outFormat = engine.outputNode.outputFormat(forBus: 0)
let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: outFormat.sampleRate, channels: outFormat.channelCount)!

engine.attach(playerNode)
engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)

class Ctx {
    var maxPeak: Float32 = 0
    var buffers: Int = 0
}
let ctx = Ctx()
let ctxPtr = Unmanaged.passRetained(ctx)

let cb: AURenderCallback = { (inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData) -> OSStatus in
    let context = Unmanaged<Ctx>.fromOpaque(inRefCon).takeUnretainedValue()
    context.buffers += 1
    return noErr
}

var cbStruct = AURenderCallbackStruct(inputProc: cb, inputProcRefCon: ctxPtr.toOpaque())
AudioUnitSetProperty(unit!, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cbStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

try? engine.start()
playerNode.play()

AudioUnitInitialize(unit!)
AudioOutputUnitStart(unit!)

for i in 1...3 {
    Thread.sleep(forTimeInterval: 1.0)
    print("Sec \(i): peak = \(ctx.maxPeak), total buffers = \(ctx.buffers)")
}

AudioOutputUnitStop(unit!)
playerNode.stop()
engine.stop()
AudioHardwareDestroyAggregateDevice(aggID)
AudioHardwareDestroyProcessTap(tapID)
