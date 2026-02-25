#include "../tools/tools.h"

#include <EGrabber.h>

using namespace Euresys;

namespace {

class MyGrabber: public EGrabber<CallbackOnDemand> {
    public:
        MyGrabber(EGenTL &gentl)
        : EGrabber<CallbackOnDemand>(gentl)
        {
        }
        void grab(const BufferIndexRange &range, size_t bufferCount) {
            Tools::log("Grabbing " + Tools::toString(bufferCount) +
                " buffers with buffers of range [" + Tools::toString(range.begin) +
                ".." + Tools::toString(range.end) + "[");
            resetBufferQueue(range); // discard all buffers and only queue the range
            start(bufferCount); // start grabbing
            // and make sure all requested buffers are acquired
            for (size_t i = 0; i < bufferCount; ++i) {
                pop();
            }
        }
        void process(const BufferIndexRange &range, size_t bufferCount) {
            Tools::log("Processing first " + Tools::toString(bufferCount) +
                " buffers of range [" + Tools::toString(range.begin) +
                ".." + Tools::toString(range.end) + "[");
            for (size_t i = 0; i < bufferCount; ++i) {
                NewBufferData bufferData(getBufferData(range.indexAt(i)));
                Buffer buffer(bufferData);
                Tools::log("#" + Tools::toString(i));
                Tools::log("  BUFFER_INFO_BASE = "
                    + Tools::toHexString(buffer.getInfo<void *>(*this, gc::BUFFER_INFO_BASE)));
            }
        }
};

}

static void sample() {
    EGenTL genTL;
    MyGrabber grabber(genTL);

    // announce first set of buffers (bufferSet1: 10 buffers)
    grabber.runScript(Tools::getSampleFilePath("221-queue-buffer-ranges.bufferSet1.js"));
    BufferIndexRange bufferSet1(grabber.announceAndQueue(GenTLMemory(), 10));

    // announce second set of buffers (bufferSet2: 20 buffers)
    grabber.runScript(Tools::getSampleFilePath("221-queue-buffer-ranges.bufferSet2.js"));
    BufferIndexRange bufferSet2(grabber.announceAndQueue(GenTLMemory(), 20));

    // grab 5 buffers using only buffers of bufferSet1
    grabber.grab(bufferSet1, 5);
    // grab 15 buffers using only buffers of bufferSet2
    grabber.grab(bufferSet2, 15);
    // process the first 5 buffers of bufferSet1
    grabber.process(bufferSet1, 5);
    // process the first 15 buffers of bufferSet2
    grabber.process(bufferSet2, 15);
}

static Tools::Sample addSample(__FILE__, sample, "Create and use 2 sets of buffers configured differently");
