#include <iostream>
#include <stdexcept>
#include <thread>
#include <atomic>
#include <mutex>
#include <condition_variable>
#include <chrono>
#include <EGrabber.h>
#include <FormatConverter.h>
#include "../common/window.h"

using namespace Euresys;

std::unique_ptr<Buffer> currentBuffer;
std::mutex mutex;
std::condition_variable cv;

void grab(EGrabber<CallbackOnDemand> &grabber) {
    try {
        while (grabber.getInfo<StreamModule, bool>(gc::STREAM_INFO_IS_GRABBING)) {
            std::unique_ptr<Buffer> buffer(new Buffer(grabber.pop()));
            {
                std::lock_guard<std::mutex> lock(mutex);
                if (currentBuffer) {
                    currentBuffer->push(grabber);
                }
                currentBuffer.swap(buffer);
            }
            cv.notify_one();
        }
    } catch (const std::exception &e) {
        std::cerr << e.what() << std::endl;
    } catch (...) {
        std::cerr << "uncaught exception!" << std::endl;
    }
}

std::unique_ptr<Buffer> getLatestBuffer() {
    std::unique_ptr<Buffer> buffer;
    {
        std::unique_lock<std::mutex> lock(mutex);
        cv.wait_for(lock, std::chrono::milliseconds(100));
        if (currentBuffer) {
            buffer.swap(currentBuffer);
        }
    }
    return buffer;
}

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
    std::thread grabberThread(grab, std::ref(grabber));
    while (window.isAlive()) {
        std::unique_ptr<Buffer> buffer(getLatestBuffer());
        if (buffer) {
            FormatConverter::Auto rgb(converter, FormatConverter::OutputFormat("RGB8"),
                buffer->getInfo<uint8_t *>(grabber, gc::BUFFER_INFO_BASE),
                buffer->getInfo<uint64_t>(grabber, gc::BUFFER_INFO_PIXELFORMAT),
                buffer->getInfo<size_t>(grabber, gc::BUFFER_INFO_WIDTH),
                buffer->getInfo<size_t>(grabber, gc::BUFFER_INFO_DELIVERED_IMAGEHEIGHT));
            window.updateImage(rgb.getBuffer(), rgb.getBufferSize());
            buffer->push(grabber);
        }
    }
    grabber.stop();
    grabber.cancelPop();
    grabberThread.join();
    return 0;
}
