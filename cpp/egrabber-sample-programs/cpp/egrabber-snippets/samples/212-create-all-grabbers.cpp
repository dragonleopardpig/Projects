#include "../tools/tools.h"

#include <sstream>
#include <map>
#include <EGrabber.h>

using namespace Euresys;

namespace {

    class MyGrabber: public EGrabberCallbackSingleThread {
        public:
            MyGrabber(EGenTL &gentl, int interfaceIndex, int deviceIndex)
            : EGrabberCallbackSingleThread(gentl, interfaceIndex, deviceIndex)
            , grabberIndex(interfaceIndex)
            , deviceIndex(deviceIndex)
            {
                reallocBuffers(10);
            }
            ~MyGrabber()
            {
                shutdown();
            }
        private:
            int grabberIndex;
            int deviceIndex;

            virtual void onNewBufferEvent(const NewBufferData& data)
            {
                ScopedBuffer buffer(*this, data);

                // note: ScopedBuffer pushes the buffer back to the input queue automatically
                uint8_t *imagePointer = buffer.getInfo<uint8_t *>(gc::BUFFER_INFO_BASE);

                std::stringstream ss;
                ss << "Image Buffer ["
                   << (void *)imagePointer
                   << "] from Grabber["
                   << grabberIndex
                   << "], Device["
                   << deviceIndex
                   << "]";

                Tools::log(ss.str());
                memento(ss.str());
            }

            virtual void onIoToolboxEvent(const IoToolboxData &data)
            {}

            virtual void onCicEvent(const CicData &data)
            {}

            virtual void onDataStreamEvent(const DataStreamData &data)
            {}

            virtual void onCxpInterfaceEvent(const CxpInterfaceData &data)
            {}

            virtual void onDeviceErrorEvent(const DeviceErrorData &data)
            {}

            virtual void onCxpDeviceEvent(const CxpDeviceData &data)
            {}

            virtual void onRemoteDeviceEvent(const RemoteDeviceData &data)
            {}
    };

    class MyDevices {
        public:
            MyDevices()
            : grabberCount(0)
            {
                GenTL::TL_HANDLE tl = genTL.tlOpen();
                try {
                    grabberCount = genTL.tlGetNumInterfaces(tl);
                    Tools::log("Number of frame grabbers: " + Tools::toString(grabberCount));
                    for (uint32_t grabberIndex = 0; grabberIndex < grabberCount; ++grabberIndex) {
                        std::string ifID = genTL.tlGetInterfaceID(tl, grabberIndex);
                        Tools::log("  Grabber Index [" + Tools::toString(grabberIndex) + "] " + ifID);
                        GenTL::IF_HANDLE ifh = genTL.tlOpenInterface(tl, ifID);
                        uint32_t deviceCount = genTL.ifGetNumDevices(ifh);
                        Tools::log("    Number of devices: " + Tools::toString(deviceCount));
                        for (uint32_t deviceIndex = 0; deviceIndex < deviceCount; ++deviceIndex) {
                            MyGrabber *pGrabber = new MyGrabber(genTL, grabberIndex, deviceIndex);
                            // build a map to manage the grabber pointers
                            grabbersMap[grabberIndex][deviceIndex] = pGrabber;
                            std::string deviceVendor = "N/A";
                            try {
                                deviceVendor = pGrabber->getString<Euresys::DeviceModule>("DeviceVendorName");
                            } catch (const gentl_error &) {
                            }
                            std::string deviceModel = "N/A";
                            try {
                                deviceModel = pGrabber->getString<Euresys::DeviceModule>("DeviceModelName");
                            } catch (const gentl_error &) {
                            }
                            std::string cameraResolution =
                                Tools::toString(pGrabber->getWidth()) + "x" + Tools::toString(pGrabber->getHeight());
                            Tools::log("      Device index: " + Tools::toString(deviceIndex));
                            Tools::log("        Device vendor: " + deviceVendor);
                            Tools::log("        Device model:  " + deviceModel);
                            Tools::log("        Resolution:    " + cameraResolution);
                        }
                        genTL.ifClose(ifh);
                    }
                } catch (...) {
                    // note: interfaces and devices opened from the transport
                    // layer (TL) are automatically closed when the TL is closed
                    genTL.tlClose(tl);
                    throw;
                }
                genTL.tlClose(tl);
            }
            ~MyDevices()
            {
                for (grabbersMap_t::iterator gIter = grabbersMap.begin(); gIter != grabbersMap.end(); ++gIter) {
                    devicesMap_t &devicesMap = gIter->second;
                    for (devicesMap_t::iterator dIter = devicesMap.begin(); dIter != devicesMap.end(); ++dIter) {
                        MyGrabber* pGrabber = dIter->second;
                        if (pGrabber) {
                            delete pGrabber;
                        }
                    }
                }
            }
            MyGrabber* GetDevice(int grabberIndex, int deviceIndex)
            {
                return grabbersMap[grabberIndex][deviceIndex];
            }

            uint32_t grabberCount;
            typedef std::map<int, MyGrabber *> devicesMap_t;
            typedef std::map<int, devicesMap_t> grabbersMap_t;
            grabbersMap_t grabbersMap;
        private:
            EGenTL genTL;
    };

};

static void sample() {
    // collect all available grabbers in the "devices" instance
    MyDevices devices;

    // try to get the first device on the first interface
    MyGrabber* pDevice1 = devices.GetDevice(0, 0);
    // try to get the first device on the second interface
    MyGrabber* pDevice2 = devices.GetDevice(1, 0);

    if (pDevice1) {
        pDevice1->runScript(Tools::getSampleFilePath("212-create-all-grabbers.setup.js"));
    }
    if (pDevice2) {
        pDevice2->runScript(Tools::getSampleFilePath("212-create-all-grabbers.setup.js"));
    }

    // acquire one frame on those devices
    if (pDevice1) {
        pDevice1->start(1);
    }
    if (pDevice2) {
        pDevice2->start(1);
    }

    Tools::sleepMs(2000);
    // the destructor of "devices" will cleanup (stop and delete) the grabbers
}

static Tools::DeprecatedSample addSample(__FILE__, sample, "Create available grabbers\n"
    "Please use EGrabberDiscovery to list the available grabbers (cf. 150-discover)");
