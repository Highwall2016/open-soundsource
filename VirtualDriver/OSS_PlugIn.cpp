#include <aspl/Plugin.hpp>
#include <aspl/Driver.hpp>
#include <aspl/Context.hpp>
#include "OSS_Device.hpp"

// Define a custom plugin context that creates our custom device
class OSSPlugin : public aspl::Plugin {
public:
    explicit OSSPlugin(std::shared_ptr<const aspl::Context> inContext)
        : aspl::Plugin(inContext)
    {
        // Instantiate and add our virtual device immediately
        auto device = std::make_shared<OSSDevice>(GetContext());
        device->AddStreamAsync(aspl::Direction::Output);
        AddDevice(device);
    }
};

// Expose the factory function required by CoreAudio.
// The UUID "443AB605-A77E-4F39-A14C-E4369CAAC85E" must match VirtualDriver-Info.plist
extern "C" void* OpenSoundSourcePluginFactory(CFAllocatorRef, CFUUIDRef inRequestedTypeUUID)
{
    if (!CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return nullptr;
    }
    
    static std::shared_ptr<aspl::Driver> driver = []() {
        auto context = std::make_shared<aspl::Context>();
        auto plugin = std::make_shared<OSSPlugin>(context);
        return std::make_shared<aspl::Driver>(context, plugin);
    }();
    
    return driver->GetReference();
}
