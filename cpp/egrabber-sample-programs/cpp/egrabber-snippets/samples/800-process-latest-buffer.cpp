#include "../tools/tools.h"

#include <mutex>
#include <atomic>
#include <iostream>
#include <thread>
#include <condition_variable>
#include <EGrabber.h>

using namespace Euresys;

constexpr int RUNNING_TIME_IN_MS = 3000;
constexpr int PROCESSING_TIME_IN_MS = 100;

namespace {
    class MyGrabber : public EGrabberCallbackMultiThread {
    public:
        MyGrabber(EGenTL &gentl)
            : EGrabberCallbackMultiThread(gentl)
            , isRunning(false)
            , totalBufferCount(0)
            , discardedBufferCount(0) {
        }

        ~MyGrabber() {
            shutdown();
        }

        void go() {
            bufferToProcess.reset();
            totalBufferCount = 0;
            discardedBufferCount = 0;

            reallocBuffers(3);

            isRunning.store(true);
            std::thread processingThread(&MyGrabber::processImage, this);

            start();
            Tools::sleepMs(RUNNING_TIME_IN_MS);
            stop();

            isRunning.store(false);
            processingThread.join();

            printStatistics();
        }
    private:
        void getBufferInfo(std::unique_ptr<Buffer> &buffer, size_t &imageWidth, size_t &imageHeight, uint64_t &timestamp) {
            imageWidth = buffer->getInfo<size_t>(*this, gc::BUFFER_INFO_WIDTH);
            imageHeight = buffer->getInfo<size_t>(*this, gc::BUFFER_INFO_DELIVERED_IMAGEHEIGHT);
            timestamp = buffer->getInfo<uint64_t>(*this, gc::BUFFER_INFO_TIMESTAMP);
        }

        virtual void onNewBufferEvent(const NewBufferData &data) {
            std::unique_ptr<Buffer> buffer(new Buffer(data));
            {
                std::lock_guard<std::mutex> lock(processImageMutex);
                if (bufferToProcess) {
                    ++discardedBufferCount;
                    size_t imageWidth = 0;
                    size_t imageHeight = 0;
                    uint64_t timestamp = 0;
                    getBufferInfo(bufferToProcess, imageWidth, imageHeight, timestamp);
                    std::cout << Tools::formatTimestamp(timestamp) << ": skipping " << imageWidth << "x" << imageHeight << " buffer" << std::endl;
                    bufferToProcess->push(*this);
                }
                bufferToProcess.swap(buffer);
            }
            processImageCV.notify_one();
            ++totalBufferCount;
        }

        void processImage() {
            while (isRunning.load()) {
                std::unique_ptr<Buffer> buffer;
                {
                    std::unique_lock<std::mutex> lock(processImageMutex);
                    processImageCV.wait_for(lock, std::chrono::milliseconds(100));
                    if (bufferToProcess) {
                        bufferToProcess.swap(buffer);
                    }
                }
                if (buffer) {
                    size_t imageWidth = 0;
                    size_t imageHeight = 0;
                    uint64_t timestamp = 0;
                    getBufferInfo(buffer, imageWidth, imageHeight, timestamp);
                    std::cout << Tools::formatTimestamp(timestamp) << ": processing " << imageWidth << "x" << imageHeight << " buffer" << std::endl;
                    Tools::sleepMs(PROCESSING_TIME_IN_MS); // simulate that the processing takes some time
                    buffer->push(*this);
                }
            }
        }

        void printStatistics() {
            uint64_t processedBufferCount = totalBufferCount - discardedBufferCount;
            std::cout << "Total buffer count:     " << totalBufferCount << std::endl;
            std::cout << "Discarded buffer count: " << discardedBufferCount << std::endl;
            std::cout << "Processed buffer count: " << processedBufferCount << std::endl;
            std::cout << "FPS (expected):         " << totalBufferCount * 1000.f / RUNNING_TIME_IN_MS << std::endl;
            std::cout << "FPS (actual):           " << processedBufferCount * 1000.f / RUNNING_TIME_IN_MS << std::endl;
        }

        std::atomic<bool> isRunning;
        std::mutex processImageMutex;
        std::condition_variable processImageCV;
        uint64_t totalBufferCount;
        uint64_t discardedBufferCount;
        std::unique_ptr<Buffer> bufferToProcess;
    };
}

static void sample() {
    EGenTL genTL;
    MyGrabber grabber(genTL);
    grabber.go();
}

static Tools::Sample addSample(__FILE__, sample, "Simulate a busy environment and acquire images, discarding some buffers when busy");
