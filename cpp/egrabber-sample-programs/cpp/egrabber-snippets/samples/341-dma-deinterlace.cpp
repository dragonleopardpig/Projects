#include "../tools/tools.h"

#include <EGrabber.h>
#include <FormatConverter.h>

using namespace Euresys;

static void sample() {
    EGenTL genTL(Coaxlink()); // load CoaxLink GenTL producer
    EGrabberDiscovery egrabberDiscovery(genTL);
    egrabberDiscovery.discover(false);
    EGrabber<CallbackOnDemand> grabber(egrabberDiscovery.egrabbers(0));
    FormatConverter converter(genTL); // create rgb converter environment

    std::string pixelFormat = grabber.getString<StreamModule>("PixelFormat");
    size_t sizeOfPixel = genTL.imageGetBytesPerPixel(pixelFormat);
    size_t width = grabber.getWidth();
    size_t height = grabber.getHeight();

    if (height & 1) {
        throw std::runtime_error("The remote Height is not a multiple of 2");
    }

    grabber.execute<StreamModule>("StreamReset");
    grabber.setString<StreamModule>("DmaProgramSelector", "DmaProgram1");
    grabber.execute<StreamModule>("DmaResetProgram");

    // Even lines are stored from the beginning of the buffer
    grabber.setInteger<StreamModule>("DmaSegmentSize", width * sizeOfPixel);
    grabber.setInteger<StreamModule>("DmaSegmentOffsetIncrement", grabber.getInteger<StreamModule>("DmaSegmentSize"));
    grabber.setInteger<StreamModule>("DmaSegmentOffset", 0);
    grabber.execute<StreamModule>("DmaAddSegment");
    // Odd lines are stored from the middle of the buffer
    grabber.setInteger<StreamModule>("DmaSegmentOffset", width * sizeOfPixel * height / 2);
    grabber.execute<StreamModule>("DmaAddSegment");
    // The sequence of segments above is repeated "half the height of the image" times
    grabber.setInteger<StreamModule>("DmaSegmentsRepeatCount", height / 2);
    grabber.execute<StreamModule>("DmaAddSequence");

    grabber.setInteger<StreamModule>("DmaProgramWidth", width);
    grabber.setInteger<StreamModule>("DmaProgramHeight", height);
    grabber.setInteger<StreamModule>("DmaProgramPitch", width * sizeOfPixel);
    grabber.setString<StreamModule>("DmaProgramPixelFormat", pixelFormat);
    grabber.execute<StreamModule>("DmaCompleteProgram");

    grabber.setString<StreamModule>("StripeArrangement", "DmaProgram1");

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
        bgr.saveToDisk(Tools::getEnv("sample-output-path") + "/frame.NNN.png", frame);
    }
}

static Tools::Sample addSample(__FILE__, sample, "Grab and deinterlace N frames");
