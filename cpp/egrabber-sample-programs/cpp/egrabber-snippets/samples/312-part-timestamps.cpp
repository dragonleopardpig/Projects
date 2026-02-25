#include "../tools/tools.h"

#include <EGrabber.h>

using namespace Euresys;

static void sample() {
    EGenTL genTL;
    EGrabber<CallbackOnDemand> grabber(genTL);

    grabber.setInteger<StreamModule>("BufferPartCount", 10);

    grabber.reallocBuffers(3);
    grabber.start();

    for (size_t b = 0; b < 3; ++b) {
        ScopedBuffer buffer(grabber);
        std::vector<char> tsData(buffer.getInfo<std::vector<char> >(ge::BUFFER_INFO_CUSTOM_PART_TIMESTAMPS)); // get timestamp data
        const size_t CNT = tsData.size() / sizeof(uint64_t);
        Tools::log("Buffer #" + Tools::toString(b) + " with " + Tools::toString(CNT) + " part timestamps:");
        uint64_t *ts = (uint64_t *)&tsData[0]; // extract part timestamp
        for (size_t j = 0; j < CNT && ts; ++j, ++ts) {
            Tools::log("  " + Tools::toString(*ts) + " us");
        }
    }
}

static Tools::Sample addSample(__FILE__, sample, "Show timestamp of each buffer part in HFR mode");
