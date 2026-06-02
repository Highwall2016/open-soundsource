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
print("Matched Chrome processes: \(matched)")
if matched.isEmpty { 
    print("Chrome not found or no process objects.")
    exit(0) 
}

let desc = CATapDescription(stereoMixdownOfProcesses: matched)
desc.uuid = UUID()
desc.isPrivate = false
desc.muteBehavior = .muted // Test with muted!

var tapID = AudioObjectID(kAudioObjectUnknown)
var tapStatus = AudioHardwareCreateProcessTap(desc, &tapID)
if tapStatus != noErr {
    print("Failed to create process tap: \(tapStatus)")
    exit(1)
}

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
    kAudioAggregateDeviceNameKey: "TestTapAggMonitor",
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

var captureASBD = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
AudioUnitSetProperty(unit!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &captureASBD, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

class Ctx {
    var maxPeak: Float32 = 0
    var callbacks: Int = 0
}
let ctx = Ctx()
let ctxPtr = Unmanaged.passRetained(ctx)

let cb: AURenderCallback = { (inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData) -> OSStatus in
    let context = Unmanaged<Ctx>.fromOpaque(inRefCon).takeUnretainedValue()
    context.callbacks += 1
    
    // We must pass a valid AudioUnit into AudioUnitRender. Since we didn't pass `unit` in inRefCon, we need to pass it globally or via struct.
    return noErr // We'll redefine this below
}

// Re-do callback safely
struct RenderContext {
    var unit: AudioUnit
    var maxPeak: Float32 = 0
    var callbacks: Int = 0
}
var rCtx = RenderContext(unit: unit!)

let realCb: AURenderCallback = { (inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData) -> OSStatus in
    let ctx = inRefCon.bindMemory(to: RenderContext.self, capacity: 1)
    ctx.pointee.callbacks += 1
    
    let ablPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
    ablPtr.pointee.mNumberBuffers = 1
    ablPtr.pointee.mBuffers.mNumberChannels = 2
    ablPtr.pointee.mBuffers.mDataByteSize = inNumberFrames * 2 * 4
    ablPtr.pointee.mBuffers.mData = malloc(Int(ablPtr.pointee.mBuffers.mDataByteSize))
    
    let status = AudioUnitRender(ctx.pointee.unit, ioActionFlags, inTimeStamp, 1, inNumberFrames, ablPtr)
    if status == noErr {
        let ptr = ablPtr.pointee.mBuffers.mData!.bindMemory(to: Float32.self, capacity: Int(inNumberFrames * 2))
        var currentPeak: Float32 = 0
        for i in 0..<Int(inNumberFrames * 2) {
            let s = abs(ptr[i])
            if s > currentPeak { currentPeak = s }
            if s > ctx.pointee.maxPeak { ctx.pointee.maxPeak = s }
        }
        if currentPeak > 0 {
            print(String(format: "Callback %d: frames=%d, peak=%.5f", ctx.pointee.callbacks, inNumberFrames, currentPeak))
        }
    }
    free(ablPtr.pointee.mBuffers.mData)
    ablPtr.deallocate()
    return noErr
}

var cbStruct = AURenderCallbackStruct(inputProc: realCb, inputProcRefCon: &rCtx)
AudioUnitSetProperty(unit!, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cbStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

AudioUnitInitialize(unit!)
AudioOutputUnitStart(unit!)

print("Monitoring Chrome audio for 10 seconds. Play audio in Chrome NOW!")
for i in 1...10 {
    Thread.sleep(forTimeInterval: 1.0)
    print("Sec \(i)... max peak so far: \(rCtx.maxPeak), total callbacks: \(rCtx.callbacks)")
}

AudioOutputUnitStop(unit!)
AudioHardwareDestroyAggregateDevice(aggID)
AudioHardwareDestroyProcessTap(tapID)
