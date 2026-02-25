#include "../tools/tools.h"

#include <EGrabber.h>

using namespace Euresys;

namespace {

// Configure EGrabber in callback multi-thread mode
class MyGrabber: public EGrabberCallbackMultiThread {
    public:
        MyGrabber(EGenTL &gentl)
        : EGrabberCallbackMultiThread(gentl)
        , frame(0)
        {
            runScript(Tools::getSampleFilePath("300-events-mt-cic.setup.js"));
            reallocBuffers(20);
            enableEvent<CicData>();
        }
        ~MyGrabber() {
            try {
                runScript(Tools::getSampleFilePath("300-events-mt-cic.teardown.js"));
            }
            catch (...) {
            }
            shutdown();
        }
        void go(unsigned int duration) {
            start();
            execute<DeviceModule>("StartCycle");
            Tools::log("Grabbing for " + Tools::toString(duration) + " seconds");
            Tools::sleepMs(1000 * duration);
        }
    private:
        virtual void onNewBufferEvent(const NewBufferData& data) {
            ScopedBuffer buffer(*this, data);
            ++frame;
            size_t size        = buffer.getInfo<size_t>(gc::BUFFER_INFO_DATA_SIZE);
            uint64_t timestamp = buffer.getInfo<uint64_t>(gc::BUFFER_INFO_TIMESTAMP);
            Tools::log(
                "onNewBufferEvent: frame #" + Tools::toString(frame) +
                " data size=" + Tools::toString(size) +
                " timestamp=" + Tools::formatTimestamp(timestamp));
        }
        virtual void onCicEvent(const CicData& data) {
            switch (data.numid) {
                case ge::EVENT_DATA_NUMID_CIC_CAMERA_TRIGGER_RISING_EDGE:
                    Tools::log("onCicEvent: Camera trigger rising edge: timestamp=" + Tools::formatTimestamp(data.timestamp));
                    break;
                case ge::EVENT_DATA_NUMID_CIC_CAMERA_TRIGGER_FALLING_EDGE:
                    Tools::log("onCicEvent: Camera trigger falling edge: timestamp=" + Tools::formatTimestamp(data.timestamp));
                    break;
                case ge::EVENT_DATA_NUMID_CIC_ALLOW_NEXT_CYCLE:
                    Tools::log("onCicEvent: Allow next cycle: timestamp=" + Tools::formatTimestamp(data.timestamp));
                    execute<DeviceModule>("StartCycle");
                    break;
                default:
                    break;
            }
        }
        size_t frame;
};

}

static void sample() {
    EGenTL genTL;
    MyGrabber grabber(genTL);
    grabber.go(2);
}

static Tools::Sample addSample(__FILE__, sample, "CIC events on EGrabber Multi-Thread Configuration");
