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
        void announceAndShowBufferHandles(size_t bufferCount) {
            BufferIndexRange range(reallocBuffers(bufferCount));            
            Tools::log("Using EGrabber function getBufferInfo:");
            Tools::log("--------------------------------------");
            for (size_t i = 0; i < bufferCount; ++i) {
                void  *base = getBufferInfo<void *>(range.indexAt(i), gc::BUFFER_INFO_BASE);
                size_t size = getBufferInfo<size_t>(range.indexAt(i), gc::BUFFER_INFO_SIZE);
                Tools::log(
                    "Buffer #" + Tools::toString(i) +
                    ": base = " + Tools::toHexString(base) +
                    ", size = " + Tools::toString(size)
                );
            }
            Tools::log("");
            Tools::log("Using EGrabber function getBufferData:");
            Tools::log("--------------------------------------");
            for (size_t i = 0; i < bufferCount; ++i) {
                NewBufferData bufferData = getBufferData(range.indexAt(i));
                Buffer buffer(bufferData);
                void  *base = buffer.getInfo<void *>(*this, gc::BUFFER_INFO_BASE);
                size_t size = buffer.getInfo<size_t>(*this, gc::BUFFER_INFO_SIZE);
                Tools::log(
                    "Buffer #" + Tools::toString(i) +
                    ": base = " + Tools::toHexString(base) +
                    ", size = " + Tools::toString(size)
                );
            }
        }
};

}

static void sample() {
    EGenTL genTL;
    MyGrabber grabber(genTL);
    grabber.announceAndShowBufferHandles(10);
}

static Tools::Sample addSample(__FILE__, sample, "Get info and handles of announced buffers");
