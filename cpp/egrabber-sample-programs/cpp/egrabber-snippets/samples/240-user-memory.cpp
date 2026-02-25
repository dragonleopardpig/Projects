#include "../tools/tools.h"
#include <EGrabber.h>

using namespace Euresys;

static void sample() {
    EGenTL genTL;
    EGrabber<CallbackOnDemand> myGrabber(genTL);
    size_t payLoadSize = myGrabber.getPayloadSize();
    char* userBuffer = new char[payLoadSize];
    // Announce and queue user buffer
    myGrabber.announceAndQueue(UserMemory(userBuffer, payLoadSize));
    myGrabber.start(1);
    ScopedBuffer buffer(myGrabber);
    Tools::log("User memory address: " + 
               Tools::toHexString(buffer.getInfo<void *>(gc::BUFFER_INFO_BASE)) + 
               ", buffer data size: " + 
               Tools::toString(buffer.getInfo<size_t>(gc::BUFFER_INFO_DATA_SIZE)));
    myGrabber.stop(); // Make sure the data stream is stopped before revoking the buffer
    myGrabber.reallocBuffers(0); // Revoke announced user buffer before deleting it
    delete[] userBuffer;
}

static Tools::Sample addSample(__FILE__, sample, "Grab into user allocated buffer");
