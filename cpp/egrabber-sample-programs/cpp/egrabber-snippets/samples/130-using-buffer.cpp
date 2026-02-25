#include "../tools/tools.h"

#include <EGrabber.h>
#include <FormatConverter.h>

using namespace Euresys;

static void sample() {
    EGenTL genTL; // load GenTL producer
    EGrabber<CallbackOnDemand> grabber(genTL); // create grabber
    FormatConverter converter(genTL); // create rgb converter environment

    grabber.reallocBuffers(20); // prepare 20 buffers

    grabber.start(20); // grab 20 buffers
    for (size_t frame = 0; frame < 20; ++frame) {
        Buffer buffer(grabber.pop()); // wait and get a buffer
        // Note: Class Buffer do not push the current buffer back to the input queue automatically
        uint8_t *imagePointer = buffer.getInfo<uint8_t *>(grabber, gc::BUFFER_INFO_BASE);
        // get the raw buffer image pointer and pass it to a BGR8 converter
        FormatConverter::Auto bgr(converter, FormatConverter::OutputFormat("BGR8"), imagePointer,
            buffer.getInfo<uint64_t>(grabber, gc::BUFFER_INFO_PIXELFORMAT),
            buffer.getInfo<size_t>(grabber, gc::BUFFER_INFO_WIDTH),
            buffer.getInfo<size_t>(grabber, gc::BUFFER_INFO_DELIVERED_IMAGEHEIGHT));
        // output the converted buffer
        bgr.saveToDisk(Tools::getEnv("sample-output-path") + "/frame.NNN.jpeg", frame);
        // push the buffer back to the input queue
        buffer.push(grabber);
    }
}

static Tools::Sample addSample(__FILE__, sample, "Simple Grab N frames using Buffer class");
