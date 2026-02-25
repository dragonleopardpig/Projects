#include "../tools/tools.h"

#include <EGrabber.h>
#include <FormatConverter.h>

using namespace Euresys;

static void sample() {
    EGenTL genTL(Coaxlink()); // load CoaxLink GenTL producer
    EGrabberDiscovery egrabberDiscovery(genTL);
    egrabberDiscovery.discover(false); // grabber-oriented discovery
    EGrabber<CallbackOnDemand> grabber(egrabberDiscovery.egrabbers(0));
    FormatConverter converter(genTL); // create rgb converter environment

    grabber.reallocBuffers(20); // prepare 20 buffers

    grabber.start(20); // grab 20 buffers
    for (size_t frame = 0; frame < 20; ++frame) {
        ScopedBuffer buffer(grabber); // wait and get a buffer
        // Note: ScopedBuffer pushes the buffer back to the input queue automatically
        BufferInfo bi = buffer.getInfo();
        std::string outFormat = ".jpeg";
        if (bi.pixelFormat == "Data8" || bi.width == 0) {
            outFormat = ".raw";
        }
        std::string name = Tools::getEnv("sample-output-path") + "/frame.NNN" + outFormat;
        buffer.saveToDisk(name, frame);
    }
}

static Tools::Sample addSample(__FILE__, sample, "Simple Grab N frames using ScopedBuffer class");
