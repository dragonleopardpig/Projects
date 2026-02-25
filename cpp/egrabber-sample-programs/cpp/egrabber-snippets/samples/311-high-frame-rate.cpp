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

    BufferIndexRange bir = grabber.reallocBuffers(20);
    size_t offset = 0;

    grabber.start();
    uint64_t tStart = Tools::getTimestamp();
    uint64_t tStop = tStart + static_cast<uint64_t>(10e6);
    uint64_t tShowStats = tStart + static_cast<uint64_t>(1e6);
    for (uint64_t t = tStart; t < tStop; t = Tools::getTimestamp()) { // grab for 10 seconds
        size_t bufferIndex = bir.indexAt(offset); // get index of next buffer
        uint8_t *bufferPtr = grabber.getBufferInfo<uint8_t *>(bufferIndex, gc::BUFFER_INFO_BASE);
        size_t imageSize = grabber.getBufferInfo<size_t>(bufferIndex, ge::BUFFER_INFO_CUSTOM_PART_SIZE);
        size_t imageCount = grabber.getBufferInfo<size_t>(bufferIndex, ge::BUFFER_INFO_CUSTOM_NUM_PARTS);
        // process available images
        size_t processed = 0;
        size_t delivered = 0;
        do {
            delivered = grabber.getBufferInfo<size_t>(bufferIndex, ge::BUFFER_INFO_CUSTOM_NUM_DELIVERED_PARTS);
            while (processed < delivered) {
                uint8_t *imagePtr = bufferPtr + processed * imageSize;
                processImage(imagePtr, imageSize, width, height);
                ++processed;
            }
        } while (delivered < imageCount);
        // pop buffer from output FIFO and push back into input FIFO
        ScopedBuffer buffer(grabber);
        offset = (offset + 1) % bir.size(); // update offset in a round-robin fashion over allocated buffers
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

static Tools::Sample addSample(__FILE__, sample, "Process images as soon as available in high frame rate mode for 10 seconds");
