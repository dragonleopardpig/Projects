#include "../tools/tools.h"

#include <EGrabber.h>

using namespace Euresys;

namespace {

class MyGrabber: public EGrabberCallbackMultiThread {
    public:
        MyGrabber(EGenTL &gentl)
        : EGrabberCallbackMultiThread(gentl)
        {
            runScript(Tools::getSampleFilePath("600-thread-start-stop-callbacks.setup.js"));
        }
        ~MyGrabber() {
            try {
                runScript(Tools::getSampleFilePath("600-thread-start-stop-callbacks.teardown.js"));
            }
            catch (...) {
            }
            shutdown();
        }
        void go() {
            enableEvent<DataStreamData>();
            reallocBuffers(5);
            start();
            Tools::log("Grabbing for 100 milliseconds");
            Tools::sleepMs(100);
            stop();
            disableEvent<DataStreamData>();
        }
    private:
        virtual void onNewBufferEvent(const NewBufferData &data) {
            ScopedBuffer buffer(*this, data); // re-queues buffer automatically
            Tools::log("got NewBufferEvent");
        }
        virtual void onDataStreamEvent(const DataStreamData &) {
            Tools::log("got DataStreamEvent");
        }

        virtual void onThreadStart(EventType type) {
            switch (type) {
                case NewBufferType:
                    Tools::log("Starting callback thread for NewBufferType...");
                    // specific operations
                    break;
                case DataStreamType:
                    Tools::log("Starting callback thread for DataStreamType...");
                    // specific operations
                    break;
                default:
                    break;
            }
        }
        virtual void onThreadStop(EventType type) {
            switch (type) {
                case NewBufferType:
                    Tools::log("Stopping callback thread for NewBufferType...");
                    // specific operations
                    break;
                case DataStreamType:
                    Tools::log("Stopping callback thread for DataStreamType...");
                    // specific operations
                    break;
                default:
                    break;
            }
        }
};

}

static void sample() {
    EGenTL genTL;
    MyGrabber grabber(genTL);
    grabber.go();
}

static Tools::Sample addSample(__FILE__, sample, "Perform specific operations on a callback thread when it starts/stops");
