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
    kAudioAggregateDeviceNameKey: "TestTapEngineSched",
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

class Ctx {
    var maxPeak: Float32 = 0
    var buffers: Int = 0
}
var rCtx = (unit: unit!, maxPeak: Float32(0), buffers: 0)

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
engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)

var converter: AVAudioConverter? = nil
if playbackFormat.sampleRate != captureFormat.sampleRate {
    converter = AVAudioConverter(from: captureFormat, to: playbackFormat)
}

struct CbCtx {
    var unit: AudioUnit
    var player: AVAudioPlayerNode
    var capFormat: AVAudioFormat
    var playFormat: AVAudioFormat
    var conv: AVAudioConverter?
    var maxPeak: Float32
    var buffers: Int
}
var cbCtx = CbCtx(unit: unit!, player: playerNode, capFormat: captureFormat, playFormat: playbackFormat, conv: converter, maxPeak: 0, buffers: 0)

let cb: AURenderCallback = { (inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData) -> OSStatus in
    let ptr = inRefCon.bindMemory(to: CbCtx.self, capacity: 1)
    ptr.pointee.buffers += 1
    
    // EXACTLY AS IN AudioManager.swift
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
        
        // Convert & Play
        if let conv = ptr.pointee.conv {
            let ratio = ptr.pointee.playFormat.sampleRate / ptr.pointee.capFormat.sampleRate
            let outCap = AVAudioFrameCount(Double(inNumberFrames) * ratio) + 1
            let outBuf = AVAudioPCMBuffer(pcmFormat: ptr.pointee.playFormat, frameCapacity: outCap)!
            var err: NSError?
            var consumed = false
            conv.convert(to: outBuf, error: &err) { _, outStatus in
                if !consumed { consumed = true; outStatus.pointee = .haveData; return buffer }
                outStatus.pointee = .noDataNow; return nil
            }
            if outBuf.frameLength > 0 { ptr.pointee.player.scheduleBuffer(outBuf) }
        } else {
            ptr.pointee.player.scheduleBuffer(buffer)
        }
    }
    return noErr
}
var cbStruct = AURenderCallbackStruct(inputProc: cb, inputProcRefCon: &cbCtx)
AudioUnitSetProperty(unit!, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cbStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

try? engine.start()
playerNode.play()

AudioUnitInitialize(unit!)
AudioOutputUnitStart(unit!)

for i in 1...3 {
    Thread.sleep(forTimeInterval: 1.0)
    print("Sec \(i): peak = \(cbCtx.maxPeak), total buffers = \(cbCtx.buffers)")
    cbCtx.maxPeak = 0
}

AudioOutputUnitStop(unit!)
engine.stop()
AudioHardwareDestroyAggregateDevice(aggID)
AudioHardwareDestroyProcessTap(tapID)
