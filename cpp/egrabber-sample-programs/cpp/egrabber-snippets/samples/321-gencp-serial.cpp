#include "../tools/tools.h"

#include <EGrabber.h>
#include <FormatConverter.h>

using namespace Euresys;

static void sample() {
    EGenTL genTL(Grablink()); // load GenTL producer
    {
        // open interface only to prepare GenCP communication with the camera
        EGrabber<CallbackOnDemand> grabberIf(genTL, 0, -1);
        // set the protocol to control the camera upon next IFUpdateDeviceList
        grabberIf.setString<InterfaceModule>("DeviceControlProtocol", "GenCP");
        grabberIf.execute<InterfaceModule>("DeviceUpdateList");
    }
    // open grabber and start GenCP communication with the camera
    EGrabber<CallbackOnDemand> grabber(genTL);
    FormatConverter converter(genTL); // create rgb converter environment

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

static Tools::Sample addSample(__FILE__, sample, "Simple Grab N frames with a GenCP camera");
