#include "../tools/tools.h"

#include <EGrabber.h>

using namespace Euresys;

namespace {

class MyGrabber: public EGrabber<CallbackSingleThread> {
    public:
        MyGrabber(EGenTL &gentl, int interfaceIndex, int deviceIndex, int streamIndex)
        : EGrabber<CallbackSingleThread>(gentl, interfaceIndex, deviceIndex, streamIndex)
        , dsID(getInfo<StreamModule, std::string>(gc::STREAM_INFO_ID))
        {
            runScript(Tools::getSampleFilePath("650-multistream.setup.js"));
            reallocBuffers(5);
        }
        ~MyGrabber() {
            shutdown();
        }

    private:
        const std::string dsID;

        virtual void onNewBufferEvent(const NewBufferData& data) {
            ScopedBuffer buffer(*this, data); // re-queues buffer automatically
            size_t size = buffer.getInfo<size_t>(gc::BUFFER_INFO_DATA_SIZE);
            uint64_t ts = buffer.getInfo<uint64_t>(gc::BUFFER_INFO_TIMESTAMP);
            uint16_t id = buffer.getInfo<uint16_t>(ge::BUFFER_INFO_CUSTOM_CXP_STREAMID);
            Tools::log(dsID +
                ": StreamID=" + Tools::toString(id) +
                ", data size=" + Tools::toString(size) +
                ", timestamp=" + Tools::formatTimestamp(ts));
        }
};

}

const unsigned int DURATION = 10;

static void sample() {
    EGenTL genTL;
    MyGrabber s0(genTL, 0, 0, 0);
    MyGrabber s1(genTL, 0, 0, 1);
    MyGrabber s2(genTL, 0, 0, 2);
    MyGrabber s3(genTL, 0, 0, 3);
    s0.start();
    s1.start();
    s2.start();
    s3.start();
    Tools::log("Grabbing for " + Tools::toString(DURATION) + " seconds");
    Tools::sleepMs(1000 * DURATION);
}

static Tools::Sample addSample(__FILE__, sample, "Acquire data from 4 data streams on the same device\n"
    "(on the \"1-camera, 4-data-stream\" firmware variant of Coaxlink Quad G3)");
