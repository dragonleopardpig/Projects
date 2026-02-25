#include "../tools/tools.h"

#include <EGrabber.h>

using namespace Euresys;

namespace {

// Configure EGrabber in callback single-thread mode (ordered events)
class MyGrabber: public EGrabberCallbackSingleThread {
    public:
        MyGrabber(EGenTL &gentl)
        : EGrabberCallbackSingleThread(gentl)
        {
            runScript(Tools::getSampleFilePath("301-events-st-all.setup.js"));
            reallocBuffers(20);
        }
        ~MyGrabber() {
            try {
                runScript(Tools::getSampleFilePath("301-events-st-all.teardown.js"));
            }
            catch (...) {
            }
            shutdown();
        }
        void go(unsigned int duration) {
            enableEvent<All>();
            start();
            Tools::log("Grabbing for " + Tools::toString(duration) + " seconds");
            Tools::sleepMs(1000 * duration);
            stop();
            disableEvent<All>();
        }
    private:
        virtual void onNewBufferEvent(const NewBufferData& data) {
            ScopedBuffer buffer(*this, data); // re-queues buffer automatically
            Tools::log("NewBufferEvent:    timestamp=" + Tools::formatTimestamp(data.timestamp));
        }

        template <typename T> std::string euresysEventInfo(const std::string &name, const T& data) {
            std::string tab(Tools::spaces(name.size()));
            return name + "timestamp=" + Tools::formatTimestamp(data.timestamp) +
                "\n" + tab + "numid=" + Tools::toHexString(data.numid) +
                "\n" + tab + "EventSpecific=" + Tools::toHexString(data.context1) +
                "\n" + tab + "LineStatusAll=" + Tools::toHexString(data.context2) +
                "\n" + tab + "EventCount=" + Tools::toString(data.context3);
        }
        virtual void onIoToolboxEvent(const IoToolboxData &data) {
            Tools::log(euresysEventInfo("IoToolboxEvent:    ", data));
        }
        virtual void onCicEvent(const CicData &data) {
            Tools::log(euresysEventInfo("CicEvent:          ", data));
        }
        virtual void onDataStreamEvent(const DataStreamData &data) {
            Tools::log(euresysEventInfo("DataStreamEvent:   ", data));
        }
        virtual void onCxpInterfaceEvent(const CxpInterfaceData &data) {
            Tools::log(euresysEventInfo("CxpInterfaceEvent: ", data));
        }
        virtual void onDeviceErrorEvent(const DeviceErrorData &data) {
            Tools::log(euresysEventInfo("DeviceErrorEvent: ", data));
        }
        virtual void onCxpDeviceEvent(const CxpDeviceData &data) {
            Tools::log(euresysEventInfo("CxpDeviceEvent: ", data));
        }
        virtual void onRemoteDeviceEvent(const RemoteDeviceData &data) {
            Tools::log("RemoteDeviceEvent: timestamp=" + Tools::formatTimestamp(data.timestamp));
            Tools::log("                   eventId=" + Tools::toHexString(data.eventId));
            if (data.eventNs == ge::EVENT_CUSTOM_REMOTE_DEVICE_NAMESPACE_GENICAM) {
                // Invalidate and update Genapi features related to this event
                attachEvent<RemoteModule>(data.eventId, data.data, data.size);
            }
        }
};

}

static void sample() {
    EGenTL genTL;
    MyGrabber grabber(genTL);
    grabber.go(3);
}

static Tools::Sample addSample(__FILE__, sample, "All events on EGrabber Single-Thread Configuration");
