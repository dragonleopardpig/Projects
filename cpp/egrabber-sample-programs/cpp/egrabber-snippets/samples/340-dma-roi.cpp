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
    size_t roiX = width / 4;
    size_t roiY = height / 4;
    size_t roiWidth = width / 2;
    size_t roiHeight = height / 2;

    if (roiWidth == 0) {
        throw std::runtime_error("The remote Width is too small");
    }
    if (roiHeight == 0) {
        throw std::runtime_error("The remote Height is too small");
    }

    grabber.execute<StreamModule>("StreamReset");

    grabber.setString<StreamModule>("DmaProgramSelector", "DmaProgram1");
    grabber.execute<StreamModule>("DmaResetProgram");

    // The top lines before the ROI are discarded
    if (roiY > 0) {
        grabber.setInteger<StreamModule>("DmaSegmentSize", width * sizeOfPixel);
        grabber.setInteger<StreamModule>("DmaSegmentOffset", -1);
        grabber.execute<StreamModule>("DmaAddSegment");
        grabber.setInteger<StreamModule>("DmaSegmentsRepeatCount", roiY);
        grabber.execute<StreamModule>("DmaAddSequence");
    }

    // The data on the left of the ROI is discarded
    grabber.setInteger<StreamModule>("DmaSegmentSize", roiX * sizeOfPixel);
    grabber.setInteger<StreamModule>("DmaSegmentOffset", -1);
    grabber.execute<StreamModule>("DmaAddSegment");
    // The ROI data is stored from the beginning of the buffer
    grabber.setInteger<StreamModule>("DmaSegmentSize", roiWidth * sizeOfPixel);
    grabber.setInteger<StreamModule>("DmaSegmentOffset", 0);
    grabber.setInteger<StreamModule>("DmaSegmentOffsetIncrement", grabber.getInteger<StreamModule>("DmaSegmentSize"));
    grabber.execute<StreamModule>("DmaAddSegment");
    // The remaining data on the right of the ROI is discarded
    grabber.setInteger<StreamModule>("DmaSegmentSize", (width - roiWidth - roiX) * sizeOfPixel);
    grabber.setInteger<StreamModule>("DmaSegmentOffset", -1);
    grabber.execute<StreamModule>("DmaAddSegment");
    // The sequence of segments above is repeated "height of the ROI" times
    grabber.setInteger<StreamModule>("DmaSegmentsRepeatCount", roiHeight);
    grabber.execute<StreamModule>("DmaAddSequence");

    // The remaining lines after the ROI are discarded
    if (height - roiHeight - roiY > 0) {
        grabber.setInteger<StreamModule>("DmaSegmentSize", width * sizeOfPixel);
        grabber.setInteger<StreamModule>("DmaSegmentOffset", -1);
        grabber.execute<StreamModule>("DmaAddSegment");
        grabber.setInteger<StreamModule>("DmaSegmentsRepeatCount", height - roiHeight - roiY);
        grabber.execute<StreamModule>("DmaAddSequence");
    }

    grabber.setInteger<StreamModule>("DmaProgramWidth", roiWidth);
    grabber.setInteger<StreamModule>("DmaProgramHeight", roiHeight);
    grabber.setInteger<StreamModule>("DmaProgramPitch", roiWidth * sizeOfPixel);
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

static Tools::Sample addSample(__FILE__, sample, "Grab N frames but store a smaller region in the user buffers");
