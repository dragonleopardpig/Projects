#include "../tools/tools.h"

#include <EGrabber.h>

using namespace Euresys;

static std::vector<uint32_t> getBufferMetadata(ScopedBuffer &buffer) {
    std::vector<uint32_t> bufferMetadata(4);
    bufferMetadata[0] = buffer.getInfo<uint32_t>(ge::BUFFER_INFO_CUSTOM_BUFFER_METADATA_0); // inserted buffer metadata at offset 0
    bufferMetadata[1] = buffer.getInfo<uint32_t>(ge::BUFFER_INFO_CUSTOM_BUFFER_METADATA_1); // inserted buffer metadata at offset 1
    bufferMetadata[2] = buffer.getInfo<uint32_t>(ge::BUFFER_INFO_CUSTOM_BUFFER_METADATA_2); // inserted buffer metadata at offset 2
    bufferMetadata[3] = buffer.getInfo<uint32_t>(ge::BUFFER_INFO_CUSTOM_BUFFER_METADATA_3); // inserted buffer metadata at offset 3
    return bufferMetadata;
}

static uint32_t uint32At(const uint8_t *p) {
    return p[3] << 24 | p[2] << 16 | p[1] << 8 | p[0];
}

static std::vector<std::vector<uint32_t> > getLineMetadata(ScopedBuffer &buffer) {
    const uint8_t *lineMetadataBase = buffer.getInfo<uint8_t *>(ge::BUFFER_INFO_CUSTOM_LINE_METADATA_BASE); // base address of inserted line metadata
    const size_t deliveredHeight = buffer.getInfo<size_t>(gc::BUFFER_INFO_DELIVERED_IMAGEHEIGHT);
    const size_t linePitch = buffer.getInfo<size_t>(ge::BUFFER_INFO_CUSTOM_LINE_PITCH);
    std::vector<std::vector<uint32_t> > lineMetadata(deliveredHeight, std::vector<uint32_t>(4)); // prepare 2D vector for line metadata
    for (size_t i = 0; i < deliveredHeight; ++i) {
        for (size_t j = 0; j < 4; ++j) {
            const uint8_t *p = lineMetadataBase + i * linePitch + j * 4; // get pointer to line metadata at line i and offset j
            lineMetadata[i][j] = uint32At(p); // extract 32-bit line metadata
        }
    }
    return lineMetadata;
}

static void sample() {
    EGenTL genTL;
    EGrabber<CallbackOnDemand> grabber(genTL);

    if (!grabber.getInteger<StreamModule>(query::available("MetadataInsertion"))) {
        Tools::log("MetadataInsertion is not available!");
        return;
    }

    grabber.runScript(Tools::getSampleFilePath("330-metadata-insertion.setup.js"));
    grabber.reallocBuffers(1);
    grabber.start(1);
    {
        Tools::log("Grabbing 1 buffer...");
        ScopedBuffer buffer(grabber);
        std::vector<uint32_t> bufferMetadata = getBufferMetadata(buffer);
        std::vector<std::vector<uint32_t> > lineMetadata = getLineMetadata(buffer);
        typedef std::vector<uint32_t>::const_iterator it_t;
        Tools::log("Inserted buffer metadata:");
        for (it_t it = bufferMetadata.begin(); it != bufferMetadata.end(); it++) {
            Tools::log("  " + Tools::toString(*it));
        }
        Tools::log("Inserted line metadata at line 0:");
        for (it_t it = lineMetadata.front().begin(); it != lineMetadata.front().end(); it++) {
            Tools::log("  " + Tools::toString(*it));
        }
        Tools::log("Inserted line metadata at line " + Tools::toString(lineMetadata.size() - 1) + ":");
        for (it_t it = lineMetadata.back().begin(); it != lineMetadata.back().end(); it++) {
            Tools::log("  " + Tools::toString(*it));
        }
    }
    grabber.runScript(Tools::getSampleFilePath("330-metadata-insertion.teardown.js"));
}

static Tools::Sample addSample(__FILE__, sample, "Insert buffer and line metadata into a buffer and get them");
