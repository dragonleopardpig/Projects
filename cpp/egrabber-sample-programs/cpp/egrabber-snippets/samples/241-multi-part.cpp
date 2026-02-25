#include "../tools/tools.h"

#include <EGrabber.h>
#include <FormatConverter.h>

using namespace Euresys;

static void sample() {
    static const int MAX_PARTS = 100;
    EGenTL genTL(Coaxlink()); // load CoaxLink GenTL producer
    EGrabberDiscovery egrabberDiscovery(genTL);
    egrabberDiscovery.discover(false); // grabber-oriented discovery
    EGrabber<CallbackOnDemand> grabber(egrabberDiscovery.egrabbers(0));
    FormatConverter converter(genTL); // create rgb converter environment

    grabber.reallocBuffers(20); // prepare 20 buffers

    grabber.start(20); // grab 20 buffers
    for (size_t frame = 0; frame < 20; ++frame) {
        Buffer buffer(grabber.pop()); // wait and get a buffer
        // Note: Class Buffer does not push the current buffer back to the input queue automatically
        for (uint32_t partno = 0, nparts = buffer.getNumParts(grabber); partno < nparts && partno < MAX_PARTS; partno++) {
            BufferInfo bi = buffer.getPartInfo(grabber, partno);
            if (bi.pixelFormat == "Data8" || bi.width == 0) {
                GenTL::EuresysCustomGenTL::ImageConvertInput input = IMAGE_CONVERT_INPUT(0, 0, bi.base, bi.pixelFormat.c_str(), &bi.size, NULL);
                std::string name = Tools::getEnv("sample-output-path") + "/data.NNNN.raw"; 
                genTL.imageSaveToDisk(input, name, frame * MAX_PARTS + partno);
                continue;
            }
            // get the raw buffer image pointer and pass it to a BGR8 converter
            FormatConverter::Auto bgr(converter, FormatConverter::OutputFormat("BGR8"), 
                                      reinterpret_cast<uint8_t*>(bi.base),
                                      bi.pixelFormat,
                                      bi.width,
                                      bi.deliveredHeight);
                                      
            // output the converted buffer
            bgr.saveToDisk(Tools::getEnv("sample-output-path") + "/frame.NNNN.jpeg", frame * MAX_PARTS + partno);

        }
        // push the buffer back to the input queue
        buffer.push(grabber);
    }
}

static Tools::Sample addSample(__FILE__, sample, "Grab N multi-part buffers using Buffer class");
