#include <stdexcept>
#include <EGrabber.h>
#include <FormatConverter.h>
#include "../common/window.h"

using namespace Euresys;

int main() {
    EGenTL genTL;
    EGrabberDiscovery egrabberDiscovery(genTL);
    egrabberDiscovery.discover();
    if (egrabberDiscovery.cameraCount() == 0) {
        throw std::runtime_error("No camera");
    }
    EGrabber<CallbackOnDemand> grabber(egrabberDiscovery.cameras(0));
    FormatConverter converter(genTL);
    Window window(grabber.getWidth(), grabber.getHeight());
    grabber.reallocBuffers(3);
    grabber.start();
    while (window.isAlive()) {
        ScopedBuffer buffer(grabber);
        FormatConverter::Auto rgb(converter, FormatConverter::OutputFormat("RGB8"),
            buffer.getInfo<uint8_t *>(gc::BUFFER_INFO_BASE),
            buffer.getInfo<uint64_t>(gc::BUFFER_INFO_PIXELFORMAT),
            buffer.getInfo<size_t>(gc::BUFFER_INFO_WIDTH),
            buffer.getInfo<size_t>(gc::BUFFER_INFO_DELIVERED_IMAGEHEIGHT));
        window.updateImage(rgb.getBuffer(), rgb.getBufferSize());
    }
    return 0;
}
