#include "../tools/tools.h"

#include <EGrabber.h>

using namespace Euresys;

namespace {

class MyEGrabber : public EGrabberCallbackSingleThread {
public:
    MyEGrabber(EGenTL &gentl)
    : EGrabberCallbackSingleThread(gentl)
    {
        runScript(Tools::getSampleFilePath("302-cxp-connector-detection.setup.js"));
        enableEvent<CxpInterfaceData>();
    }
    void checkCxpEvents() {
        Tools::log("Please disconnect/connect one or more connectors to see the associated events, then press Enter to terminate.");
        getchar();
    }
    ~MyEGrabber() {
        try {
            runScript(Tools::getSampleFilePath("302-cxp-connector-detection.teardown.js"));
        } catch (...) {
        }
        shutdown();
    }

private:
    virtual void onCxpInterfaceEvent(const CxpInterfaceData &data) {
        switch (data.numid) {
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_CONNECTION_DETECTED_CXP_A:
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_CONNECTION_DETECTED_CXP_B:
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_CONNECTION_DETECTED_CXP_C:
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_CONNECTION_DETECTED_CXP_D:
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_CONNECTION_DETECTED_CXP_E:
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_CONNECTION_DETECTED_CXP_F:
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_CONNECTION_DETECTED_CXP_G:
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_CONNECTION_DETECTED_CXP_H:
                Tools::log("Low level connection lock achieved on CXP connector " + Tools::toString((char)('A' + data.numid - ge::EVENT_DATA_NUMID_CXP_INTERFACE_CONNECTION_DETECTED_CXP_A)));
                break;
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_CONNECTION_UNDETECTED_CXP_A:
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_CONNECTION_UNDETECTED_CXP_B:
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_CONNECTION_UNDETECTED_CXP_C:
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_CONNECTION_UNDETECTED_CXP_D:
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_CONNECTION_UNDETECTED_CXP_E:
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_CONNECTION_UNDETECTED_CXP_F:
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_CONNECTION_UNDETECTED_CXP_G:
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_CONNECTION_UNDETECTED_CXP_H:
                Tools::log("Low level connection lock lost on CXP connector " + Tools::toString((char)('A' + data.numid - ge::EVENT_DATA_NUMID_CXP_INTERFACE_CONNECTION_UNDETECTED_CXP_A)));
                break;
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_DEVICE_0_CONFIGURING:
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_DEVICE_1_CONFIGURING:
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_DEVICE_2_CONFIGURING:
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_DEVICE_3_CONFIGURING:
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_DEVICE_4_CONFIGURING:
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_DEVICE_5_CONFIGURING:
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_DEVICE_6_CONFIGURING:
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_DEVICE_7_CONFIGURING:
                Tools::log("Configuring CoaXPress link for Device " + Tools::toString(data.numid - ge::EVENT_DATA_NUMID_CXP_INTERFACE_DEVICE_0_CONFIGURING));
                break;
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_DEVICE_0_READY:
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_DEVICE_1_READY:
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_DEVICE_2_READY:
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_DEVICE_3_READY:
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_DEVICE_4_READY:
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_DEVICE_5_READY:
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_DEVICE_6_READY:
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_DEVICE_7_READY:
                Tools::log("Device " + Tools::toString(data.numid - ge::EVENT_DATA_NUMID_CXP_INTERFACE_DEVICE_0_READY) + " is ready");
                break;
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_DEVICE_0_LOST:
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_DEVICE_1_LOST:
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_DEVICE_2_LOST:
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_DEVICE_3_LOST:
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_DEVICE_4_LOST:
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_DEVICE_5_LOST:
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_DEVICE_6_LOST:
            case ge::EVENT_DATA_NUMID_CXP_INTERFACE_DEVICE_7_LOST:
                Tools::log("Device " + Tools::toString(data.numid - ge::EVENT_DATA_NUMID_CXP_INTERFACE_DEVICE_0_LOST) + " has been lost");
                break;
            default:
                break;
        }
    }
};

};

static void sample() {
    EGenTL genTL;
    MyEGrabber grabber(genTL);
    grabber.checkCxpEvents();
}

static Tools::Sample addSample(__FILE__, sample, "Show CoaXPress events related to connection and device discovery");
