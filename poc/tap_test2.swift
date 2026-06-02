import Foundation
import CoreAudio
import AVFoundation

let bundleID = "com.google.Chrome"

// 1. Get process objects
let system = AudioObjectID(kAudioObjectSystemObject)
var addr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyProcessObjectList,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
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
            print("Found process \(p): \(b)")
        }
    }
}

let desc = CATapDescription(stereoMixdownOfProcesses: matched)
desc.uuid = UUID()
desc.isPrivate = false
desc.muteBehavior = .muted

var tapID = AudioObjectID(kAudioObjectUnknown)
let tapStatus = AudioHardwareCreateProcessTap(desc, &tapID)
print("Tap created: \(tapID) status: \(tapStatus)")

var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var uidValue: Unmanaged<CFString>?
var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
AudioObjectGetPropertyData(tapID, &uidAddr, 0, nil, &uidSize, &uidValue)
let actualUID = uidValue?.takeRetainedValue() as String? ?? desc.uuid.uuidString
print("Tap UID: \(actualUID)")

let aggDict: [String: Any] = [
    kAudioAggregateDeviceNameKey: "TestTapAgg",
    kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceIsPrivateKey: 1,
    kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: actualUID, kAudioSubTapDriftCompensationKey: false]]
]
var aggID: AudioObjectID = 0
let aggStatus = AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &aggID)
print("Agg created: \(aggID) status: \(aggStatus)")

var compDesc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
let comp = AudioComponentFindNext(nil, &compDesc)!
var unit: AudioUnit?
AudioComponentInstanceNew(comp, &unit)

var one: UInt32 = 1, zero: UInt32 = 0
AudioUnitSetProperty(unit!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4)
AudioUnitSetProperty(unit!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, 4)
AudioUnitSetProperty(unit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &aggID, 4)

let cb: AURenderCallback = { (inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData) -> OSStatus in
    let u = inRefCon.bindMemory(to: AudioUnit?.self, capacity: 1).pointee!
    
    // Allocate AudioBufferList correctly
    let ablPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
    ablPtr.pointee.mNumberBuffers = 1
    ablPtr.pointee.mBuffers.mNumberChannels = 2
    ablPtr.pointee.mBuffers.mDataByteSize = inNumberFrames * 2 * 4 // 2 channels * 4 bytes (Float32)
    ablPtr.pointee.mBuffers.mData = malloc(Int(ablPtr.pointee.mBuffers.mDataByteSize))
    
    let status = AudioUnitRender(u, ioActionFlags, inTimeStamp, 1, inNumberFrames, ablPtr)
    if status == noErr {
        let ptr = ablPtr.pointee.mBuffers.mData!.bindMemory(to: Float32.self, capacity: Int(inNumberFrames * 2))
        var peak: Float32 = 0
        for i in 0..<Int(inNumberFrames * 2) {
            let s = abs(ptr[i])
            if s > peak { peak = s }
        }
        print("Frames: \(inNumberFrames) Peak: \(peak)")
    }
    
    free(ablPtr.pointee.mBuffers.mData)
    ablPtr.deallocate()
    return noErr
}

var unitPtr = unit
var cbStruct = AURenderCallbackStruct(inputProc: cb, inputProcRefCon: &unitPtr)
AudioUnitSetProperty(unit!, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cbStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

var format = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
AudioUnitSetProperty(unit!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

AudioUnitInitialize(unit!)
var ioProc: AudioDeviceIOProc = { _,_,_,_,_,_ in return noErr }; var ioProcID: AudioDeviceIOProcID? = nil; AudioDeviceCreateIOProcID(aggID, ioProc, nil, &ioProcID); AudioDeviceStart(aggID, ioProcID); AudioOutputUnitStart(unit!)

RunLoop.main.run(until: Date(timeIntervalSinceNow: 5))

AudioOutputUnitStop(unit!)
AudioHardwareDestroyAggregateDevice(aggID)
AudioHardwareDestroyProcessTap(tapID)
