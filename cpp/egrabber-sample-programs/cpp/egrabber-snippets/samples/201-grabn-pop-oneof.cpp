#include "../tools/tools.h"

#include <EGrabber.h>
#include <FormatConverter.h>

using namespace Euresys;

static void sample() {
    EGenTL genTL;
    FormatConverter converter(genTL);
    EGrabberCallbackOnDemand grabber(genTL);
    grabber.runScript(Tools::getSampleFilePath("201-grabn-pop-oneof.setup.js"));
    try {
        grabber.reallocBuffers(20);
        grabber.enableEvent<DataStreamData>();
        Tools::log("Grabbing...");
        grabber.start(20);
        size_t frame = 0;
        try {
            for (int i = 0; i < 100; ++i) {
                // get 100 events
                // there will be new buffers and data stream events
                Euresys::OneOf<Euresys::NewBufferData, Euresys::DataStreamData> oneOf;
                int position;
                grabber.pop(oneOf, position, 1000);
                if (position == 1) {
                    Euresys::ScopedBuffer buffer(grabber, oneOf.data1);
                    // Note: ScopedBuffer pushes the buffer back to the input queue automatically
                    uint8_t *imagePointer = buffer.getInfo<uint8_t *>(gc::BUFFER_INFO_BASE);
                    // get the raw buffer image pointer and pass it to a BGR8 converter
                    FormatConverter::Auto bgr(converter, FormatConverter::OutputFormat("BGR8"), imagePointer,
                        buffer.getInfo<uint64_t>(gc::BUFFER_INFO_PIXELFORMAT),
                        buffer.getInfo<size_t>(gc::BUFFER_INFO_WIDTH),
                        buffer.getInfo<size_t>(gc::BUFFER_INFO_DELIVERED_IMAGEHEIGHT));
                    // output the converted buffer
                    bgr.saveToDisk(Tools::getEnv("sample-output-path") + "/frame.NNN.jpeg", frame++);
                } else if (position == 2) {
                    switch (oneOf.data2.numid) {
                        case ge::EVENT_DATA_NUMID_DATASTREAM_START_OF_CAMERA_READOUT:
                            Tools::log("StartOfCameraReadout");
                            break;
                        case ge::EVENT_DATA_NUMID_DATASTREAM_END_OF_CAMERA_READOUT:
                            Tools::log("EndOfCameraReadout");
                            break;
                        case ge::EVENT_DATA_NUMID_DATASTREAM_START_OF_SCAN:
                            Tools::log("StartOfScan");
                            break;
                        case ge::EVENT_DATA_NUMID_DATASTREAM_END_OF_SCAN:
                            Tools::log("EndOfScan");
                            break;
                        case ge::EVENT_DATA_NUMID_DATASTREAM_REJECTED_FRAME:
                            Tools::log("RejectedFrame");
                            break;
                        case ge::EVENT_DATA_NUMID_DATASTREAM_REJECTED_SCAN:
                            Tools::log("RejectedScan");
                            break;
                        case ge::EVENT_DATA_NUMID_DATASTREAM_TRIGGER_TO_CAMERA_READOUT_TIMEOUT:
                            Tools::log("TriggerToCameraReadoutTimeout");
                            break;
                        case ge::EVENT_DATA_NUMID_DATASTREAM_CAMERA_READOUT_TIMEOUT:
                            Tools::log("CameraReadoutTimeout");
                            break;
                        case ge::EVENT_DATA_NUMID_DATASTREAM_BROKEN_FRAME:
                            Tools::log("BrokenFrame");
                            break;
                        case ge::EVENT_DATA_NUMID_DATASTREAM_REJECTED_LINE:
                            Tools::log("RejectedLine");
                            break;
                        default:
                            break;
                    }
                }
            }
        }
        catch (const gentl_error &err) {
            if (err.gc_err == gc::GC_ERR_TIMEOUT) {
                Tools::log("Timeout -> event loop stopped");
            } else {
                Tools::log(std::string("GenTL exception: ") + err.what());
                throw;
            }
        }
    }
    catch (...) {
        grabber.runScript(Tools::getSampleFilePath("201-grabn-pop-oneof.teardown.js"));
        throw;
    }
    grabber.runScript(Tools::getSampleFilePath("201-grabn-pop-oneof.teardown.js"));
}

static Tools::Sample addSample(__FILE__, sample, "Grab N frames and get DataStream events using pop(OneOf<>)");
