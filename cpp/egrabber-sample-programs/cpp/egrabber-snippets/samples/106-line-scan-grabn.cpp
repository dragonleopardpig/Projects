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

    int64_t widthMax = grabber.getInteger<RemoteModule>("WidthMax");

    if (grabber.getInteger<StreamModule>(query::available("BufferHeight"))) {

        grabber.setInteger<RemoteModule>("Width", widthMax / 2);
        grabber.setInteger<StreamModule>("BufferHeight", widthMax / 2);
        grabber.setInteger<StreamModule>("ScanLength", widthMax / 2);

        grabber.reallocBuffers(20); // prepare 20 buffers

        grabber.start(20); // grab 20 buffers
        for (size_t frame = 0; frame < 20; ++frame) {
            ScopedBuffer buffer(grabber); // wait and get a buffer
            // Note: ScopedBuffer pushes the buffer back to the input queue automatically
            uint8_t *imagePointer = buffer.getInfo<uint8_t *>(gc::BUFFER_INFO_BASE);
            // get the raw buffer image pointer and pass it to a BGR8 converter
            FormatConverter::Auto bgr(converter, FormatConverter::OutputFormat("BGR8"), imagePointer,
                buffer.getInfo<uint64_t>(gc::BUFFER_INFO_PIXELFORMAT),
                buffer.getInfo<size_t>(gc::BUFFER_INFO_WIDTH),
                buffer.getInfo<size_t>(gc::BUFFER_INFO_DELIVERED_IMAGEHEIGHT));
            // output the converted buffer
            bgr.saveToDisk(Tools::getEnv("sample-output-path") + "/frame.NNN.jpeg", frame);
        }

    }
}

static Tools::Sample addSample(__FILE__, sample, "Set image size and Grab N frames (line-scan)");
