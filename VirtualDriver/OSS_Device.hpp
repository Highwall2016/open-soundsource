#pragma once

#include <aspl/Device.hpp>
#include <aspl/Stream.hpp>
#include <memory>

class OSSDevice : public aspl::Device {
public:
    explicit OSSDevice(std::shared_ptr<const aspl::Context> inContext);

    // Provide default parameters to register the device in CoreAudio
    static aspl::DeviceParameters MakeParameters();

    // The core real-time I/O callback
    OSStatus DoIOOperation(
        AudioObjectID objectID,
        AudioObjectID inStreamObjectID,
        UInt32 inClientID,           // This identifies the specific client (app PID)
        UInt32 inOperationID,
        UInt32 inIOBufferFrameSize,
        const AudioServerPlugInIOCycleInfo* inIOCycleInfo,
        void* ioMainBuffer,
        void* ioSecondaryBuffer
    ) override;
    
    // Add custom stream factory if needed, though libASPL provides defaults
};
