#include "../tools/tools.h"

#include <EGrabber.h>
#include <FormatConverter.h>

using namespace Euresys;

static void sample() {
    EGenTL genTL(Coaxlink()); // load CoaxLink GenTL producer
    EGrabberDiscovery discovery(genTL);
    discovery.discover(false); // grabber-oriented discovery (no JS scripts needed)
    EGrabber<CallbackOnDemand> grabber(discovery.egrabbers(0));
    FormatConverter converter(genTL); // create rgb converter environment

    grabber.runScript(Tools::getSampleFilePath("101-singleframe.setup.js"));
    grabber.reallocBuffers(1); // prepare 1 buffer
    grabber.start(1, false); // grab 1 buffer
    grabber.execute<RemoteModule>("AcquisitionStart");
    {
        ScopedBuffer buffer(grabber); // wait and get a buffer
        // Note: ScopedBuffer pushes the buffer back to the input queue automatically
        uint8_t *imagePointer = buffer.getInfo<uint8_t *>(gc::BUFFER_INFO_BASE);
        // get the raw buffer image pointer and pass it to a BGR8 converter
        FormatConverter::Auto bgr(converter, FormatConverter::OutputFormat("BGR8"), imagePointer,
            buffer.getInfo<uint64_t>(gc::BUFFER_INFO_PIXELFORMAT),
            buffer.getInfo<size_t>(gc::BUFFER_INFO_WIDTH),
            buffer.getInfo<size_t>(gc::BUFFER_INFO_DELIVERED_IMAGEHEIGHT));
        // output the converted buffer
        bgr.saveToDisk(Tools::getEnv("sample-output-path") + "/frame.NNN.jpeg", 1);
    }
}

static Tools::Sample addSample(__FILE__, sample, "Single frame grabbing using ScopedBuffer class");
