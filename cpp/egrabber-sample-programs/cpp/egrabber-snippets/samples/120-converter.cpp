#include "../tools/tools.h"

#include <EGrabber.h>
#include <FormatConverter.h>

using namespace Euresys;

static void sample() {
    EGenTL genTL; // load GenTL producer
    EGrabber<CallbackOnDemand> grabber(genTL); // create grabber
    FormatConverter converter(genTL); // create format converter environment

    grabber.reallocBuffers(1); // prepare 1 buffer
    grabber.start(1); // grab 1 buffer
    ScopedBuffer buffer(grabber); // wait and get a buffer
    uint8_t *imagePointer = buffer.getInfo<uint8_t *>(gc::BUFFER_INFO_BASE);
    uint64_t pixelFormat = buffer.getInfo<uint64_t>(gc::BUFFER_INFO_PIXELFORMAT);
    size_t width = buffer.getInfo<size_t>(gc::BUFFER_INFO_WIDTH);
    size_t height = buffer.getInfo<size_t>(gc::BUFFER_INFO_DELIVERED_IMAGEHEIGHT);

    static const uint64_t COUNT = 1000;
    uint64_t t0 = Tools::getTimestamp();
    for (size_t i = 0; i < COUNT; ++i) {
        FormatConverter::Auto rgb(converter, FormatConverter::OutputFormat("RGB8"), imagePointer, pixelFormat, width, height);
    }
    uint64_t t1 = Tools::getTimestamp();
    double dt = static_cast<double>(t1 - t0);
    Tools::log("Converted " + Tools::toString(COUNT) + " " +
               Tools::toString(width) + "x" + Tools::toString(height) + " " +
               genTL.imageGetPixelFormat(pixelFormat) + " buffers to RGB8 in " +
               Tools::toString(dt / 1e6) + "s");
    Tools::log(Tools::toString(dt / COUNT) + "us/buffer, " +
               Tools::toString(1e6 * COUNT / dt) + "fps");
}

static Tools::Sample addSample(__FILE__, sample, "Measure FormatConverter speed");
