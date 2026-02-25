#include "../tools/tools.h"
#include <EGrabber.h>
#include <FormatConverter.h>

using namespace Euresys;

static void sample() {
    EGenTL genTL(Coaxlink());
    EGrabberDiscovery discovery(genTL);

    discovery.discover(false);
    int itf = -1;
    for (int i = 0; i < discovery.interfaceCount(); i++) {
        if (discovery.deviceCount(i) > 0) {
            itf = i;
            break;
        }
    }
    if (itf < 0) {
        throw std::runtime_error("No CoaxLink device found");
    }
    EGrabber<CallbackOnDemand> grabber(discovery.streamInfo(itf, 0, 0), gc::DEVICE_ACCESS_READONLY);
    FormatConverter converter(genTL);

    grabber.runScript(Tools::getSampleFilePath("271-multicast-receiver.setup.js"));
    grabber.reallocBuffers(1);
    grabber.start(1, false);

    std::cout << "Ready to grab the image !\n";
    {
        ScopedBuffer buffer(grabber);
        uint8_t *imagePointer = buffer.getInfo<uint8_t *>(gc::BUFFER_INFO_BASE);
        FormatConverter::Auto bgr(converter, FormatConverter::OutputFormat("BGR8"), imagePointer,
            buffer.getInfo<uint64_t>(gc::BUFFER_INFO_PIXELFORMAT),
            buffer.getInfo<size_t>(gc::BUFFER_INFO_WIDTH),
            buffer.getInfo<size_t>(gc::BUFFER_INFO_DELIVERED_IMAGEHEIGHT));
        bgr.saveToDisk(Tools::getEnv("sample-output-path") + "/frame_multicast.jpeg", 1);
    }
}

static Tools::Sample addSample(__FILE__, sample, "Save the image received on the multicast group\n"
    "(call sample 271-multicast-receiver after 270-multicast-master)");
