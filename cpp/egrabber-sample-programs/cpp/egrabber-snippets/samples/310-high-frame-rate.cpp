#include "../tools/tools.h"

#include <EGrabber.h>

using namespace Euresys;

static void processImage(uint8_t *ptr, size_t size, uint64_t width, uint64_t height) {
    // processing code
}

static void sample() {
    EGenTL genTL;
    EGrabber<CallbackOnDemand> grabber(genTL);

    grabber.setInteger<StreamModule>("BufferPartCount", 1); // get image resolution
    uint64_t width = grabber.getInteger<StreamModule>("Width");
    uint64_t height = grabber.getInteger<StreamModule>("Height");

    grabber.setInteger<StreamModule>("BufferPartCount", 100); // 100 images per buffer

    grabber.reallocBuffers(20);
    grabber.start();

    uint64_t tStart = Tools::getTimestamp();
    uint64_t tStop = tStart + static_cast<uint64_t>(10e6);
    uint64_t tShowStats = tStart + static_cast<uint64_t>(1e6);
    for (uint64_t t = tStart; t < tStop; t = Tools::getTimestamp()) { // grab for 10 seconds
        ScopedBuffer buffer(grabber);
        uint8_t *bufferPtr = buffer.getInfo<uint8_t *>(gc::BUFFER_INFO_BASE);
        size_t imageSize = buffer.getInfo<size_t>(ge::BUFFER_INFO_CUSTOM_PART_SIZE);
        // process available images
        size_t delivered = buffer.getInfo<size_t>(ge::BUFFER_INFO_CUSTOM_NUM_DELIVERED_PARTS);
        size_t processed = 0;
        while (processed < delivered) {
            uint8_t *imagePtr = bufferPtr + processed * imageSize;
            processImage(imagePtr, imageSize, width, height);
            ++processed;
        }
        if (t >= tShowStats) {
            uint64_t fr = grabber.getInteger<StreamModule>("StatisticsFrameRate");
            uint64_t dr = grabber.getInteger<StreamModule>("StatisticsDataRate");
            Tools::log(Tools::toString(width) + "x" + Tools::toString(height) + " : " +
                       Tools::toString(dr) + " MB/s, " +
                       Tools::toString(fr) + " fps");
            tShowStats += static_cast<uint64_t>(1e6);
        }
    }
}

static Tools::Sample addSample(__FILE__, sample, "Grab in high frame rate mode for 10 seconds");
