#include "OSS_Device.hpp"
#include <iostream>

using namespace aspl;

OSSDevice::OSSDevice(std::shared_ptr<const Context> inContext)
    : Device(inContext, MakeParameters())
{
}

DeviceParameters OSSDevice::MakeParameters()
{
    DeviceParameters params;
    
    // Core identity
    params.Name = "OpenSoundSource";
    params.DeviceUID = "com.open-soundsource.device";
    params.ModelUID = "com.open-soundsource.model";
    params.Manufacturer = "OpenSoundSource";
    
    // Physical setup
    params.SampleRate = 48000;
    
    // Add one output stream (where apps will send audio)
    StreamParameters outStreamParams;
    outStreamParams.Direction = Direction::Output;
    outStreamParams.StartingChannel = 1;
    outStreamParams.Format.mSampleRate = 48000.0;
    
    // Default format in libASPL is already stereo, Float32 or Int16 depending on lib version, but we can just use the defaults for now.
    
    // Stream addition in libASPL v3 is done inside the plugin context or after initialization,
    // not via params.Streams. Let's handle it later or if we have to override Initialize().
    
    return params;
}

OSStatus OSSDevice::DoIOOperation(
    AudioObjectID objectID,
    AudioObjectID inStreamObjectID,
    UInt32 inClientID,
    UInt32 inOperationID,
    UInt32 inIOBufferFrameSize,
    const AudioServerPlugInIOCycleInfo* inIOCycleInfo,
    void* ioMainBuffer,
    void* ioSecondaryBuffer
)
{
    // This is the real-time audio thread callback.
    // It runs inside `coreaudiod`.
    // NO blocking, NO locks, NO allocations here.

    if (inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        // Here we receive audio from a specific app (identified by inClientID)
        // In Phase 4, we will read the client ID to look up the routing rule,
        // apply volume adjustments, and push the samples to a ring buffer 
        // bound for the correct hardware output device.
        
        // For Phase 2, we just drop the audio (it goes to the void).
    }

    return kAudioHardwareNoError;
}
