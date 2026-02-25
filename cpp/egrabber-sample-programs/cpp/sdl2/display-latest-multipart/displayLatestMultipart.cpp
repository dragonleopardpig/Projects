#include <iostream>
#include <stdexcept>
#include <thread>
#include <atomic>
#include <mutex>
#include <condition_variable>
#include <chrono>
#include <EGrabber.h>
#include <FormatConverter.h>
#include "windowsSet.h"

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
        std::cerr << "Caught " << e.what() << std::endl;
    } catch (...) {
        std::cerr << "Caught unknown exception!" << std::endl;
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
    int nparts = 1;
    int nimages = 0;
    std::string step("preparing");
    try {
        EGenTL genTL;
        EGrabberDiscovery egrabberDiscovery(genTL);
        egrabberDiscovery.discover();
        if (egrabberDiscovery.egrabberCount() == 0) {
            throw std::runtime_error("No camera");
        }
        EGrabber<CallbackOnDemand> grabber(egrabberDiscovery.cameras(0));
        FormatConverter converter(genTL);
        size_t payloadSize = grabber.getInteger<StreamModule>("PayloadSize");

        grabber.reallocBuffers(5, payloadSize);
        grabber.start(1);
        step = "configuring";

        WindowsSet windows;
        {
            Buffer buffer(grabber.pop()); // wait and get a buffer
            nparts = buffer.getNumParts(grabber);
            for (int i = 0; i < nparts; i++) {
                BufferInfo bi = buffer.getPartInfo(grabber, i);
                if (bi.pixelFormat == "Data8" || bi.width == 0) {
                    std::cout << "Part " << i << " is not an image" << std::endl;
                } else {
                    nimages++;
                    std::cout << "Creating " << bi.width << "x" << bi.deliveredHeight << " window for part " << i << std::endl;
                    windows.add(i, new Window(bi.width, bi.deliveredHeight));
                }
            }
        }
        step = "running";
        grabber.start();
        std::thread grabberThread(grab, std::ref(grabber));
        try {
            while (!windows.empty()) {
                std::unique_ptr<Buffer> buffer(getLatestBuffer());
                if (!buffer) {
                    continue;
                }
                int bufParts = buffer->getNumParts(grabber);
                for (int part = 0; part < nparts && part < bufParts; part++) {
                    Window *win = windows.get(part);
                    if (win == nullptr) {
                        continue;
                    }
                    BufferInfo bi = buffer->getPartInfo(grabber, part);
                    if (bi.pixelFormat == "Data8" || bi.width == 0) {
                        std::cerr << "Unexpected non-image contents in part " << part << std::endl;
                        continue;
                    }
                    std::cout << "Convert " << bi.width << "x" << bi.deliveredHeight << " " << bi.pixelFormat << " to RGB8 for part " << part << std::endl;
                    FormatConverter::Auto rgb(converter, FormatConverter::OutputFormat("RGB8"),
                                              reinterpret_cast<uint8_t *>(bi.base),
                                              bi.pixelFormat,
                                              bi.width,
                                              bi.deliveredHeight);
                    win->updateImage(rgb.getBuffer(), rgb.getBufferSize());
                }
                buffer->push(grabber);
            }
            std::cout << "All windows closed" << std::endl;
        } catch (std::runtime_error &re) {
            std::cerr << "Interrupted by " << re.what() << std::endl;
        }
        step = "closing";
        grabber.stop();
        grabber.cancelPop();
        grabberThread.join();
    } catch (const std::runtime_error& rex) {
        std::cerr << "Error while " << step << " stream: " << rex.what() << std::endl;
    }
    return 0;
}
