#include "../tools/tools.h"

#include <EGrabber.h>

using namespace Euresys;
namespace {

class MyGrabber: public EGrabberCallbackSingleThread {
    public:
        MyGrabber(EGenTL &gentl, int interfaceIndex, int deviceIndex, std::string interfaceId, std::string deviceId)
            : EGrabberCallbackSingleThread(gentl, interfaceIndex, deviceIndex)
            , interfaceId(interfaceId)
            , deviceId(deviceId) {
            reallocBuffers(10);
        }
        ~MyGrabber() {
            shutdown();
        }
    private:
        std::string interfaceId;
        std::string deviceId;
        virtual void onNewBufferEvent(const NewBufferData& data) {
            ScopedBuffer buffer(*this, data); // re-queues buffer automatically
            Tools::log("got a buffer from: " + interfaceId + " <" + deviceId +">\n");
        }
};

}

static void sample() {
    EGenTL genTL;
    std::vector<MyGrabber *> grabbers;
    gc::TL_HANDLE tl = genTL.tlOpen();
    uint32_t numInterfaces = genTL.tlGetNumInterfaces(tl);
    for (uint32_t interfaceIndex = 0; interfaceIndex < numInterfaces; interfaceIndex++) {
        std::string interfaceID = genTL.tlGetInterfaceID(tl, interfaceIndex);
        gc::IF_HANDLE interfaceHandle = genTL.tlOpenInterface(tl, interfaceID);
        uint32_t numDevice = genTL.ifGetNumDevices(interfaceHandle);
        for (uint32_t deviceIndex = 0; deviceIndex < numDevice; deviceIndex++) {
            std::string deviceID = genTL.ifGetDeviceID(interfaceHandle, deviceIndex);
            gc::DEV_HANDLE deviceHandle = genTL.ifOpenDevice(interfaceHandle, deviceID);
            try {
                if (genTL.devGetPort(deviceHandle)) {
                    grabbers.push_back(new MyGrabber(genTL, interfaceIndex, deviceIndex, interfaceID, deviceID));
                }
            } catch (const gentl_error &) {
                Tools::log("no camera connected on " + interfaceID + " <" + deviceID + ">");
            }
        }
    }
    for (uint32_t grabberIndex = 0; grabberIndex < grabbers.size(); grabberIndex++) {
        grabbers[grabberIndex]->start();
    }
    Tools::sleepMs(2000); // acquire images for 2 seconds
    while (!grabbers.empty()) {
        delete grabbers.back();
        grabbers.pop_back();
    }
}

static Tools::Sample addSample(__FILE__, sample, "Acquire data from all cameras");
