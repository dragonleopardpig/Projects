#include <iostream>
#include <EGrabber.h>

void grab() {
    Euresys::EGenTL gentl;
    Euresys::EGrabber<> grabber(gentl);

    grabber.reallocBuffers(3);
    grabber.start(10);
    for (size_t i = 0; i < 10; ++i) {
        Euresys::ScopedBuffer buf(grabber);
        void *ptr = buf.getInfo<void *>(GenTL::BUFFER_INFO_BASE);
        uint64_t ts = buf.getInfo<uint64_t>(GenTL::BUFFER_INFO_TIMESTAMP);
        std::cout << "buffer address: " << ptr << ", timestamp: "
                  << ts << " us" << std::endl;
    }
}

int main() {
    try {
        grab();
    } catch (const std::exception &e) {
        std::cout << "error: " << e.what() << std::endl;
    }
}
