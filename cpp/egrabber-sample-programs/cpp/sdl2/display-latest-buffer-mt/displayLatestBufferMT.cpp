#include <iostream>
#include <iomanip>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <atomic>
#include <EGrabber.h>
#include <FormatConverter.h>
#include "../common/window.h"

using namespace Euresys;

class MyGrabber : public EGrabberCallbackMultiThread {
public:
    MyGrabber(EGenTL &gentl)
        : EGrabberCallbackMultiThread(gentl)
        , converter(Euresys::FormatConverter(gentl))
        , totalBufferCount(0)
        , totalDiscardedBufferCount(0)
        , statisticsBufferCount(0)
        , statisticsDiscardedBufferCount(0)
        , window(getWidth(), getHeight()) {
    }

    ~MyGrabber() {
        shutdown();
    }

    void go() {
        bufferToProcess.reset();
        totalBufferCount = 0;
        totalDiscardedBufferCount = 0;
        statisticsBufferCount = 0;
        statisticsDiscardedBufferCount = 0;

        reallocBuffers(3);

        std::thread statisticsThread(&MyGrabber::updateStatistics, this);

        start();
        while (window.isAlive()) {
            processImage();
        }
        stop();

        statisticsThread.join();
    }

private:
    virtual void onNewBufferEvent(const NewBufferData &data) {
        bool wasDiscarded = false;
        std::unique_ptr<Buffer> buffer(new Buffer(data));
        {
            std::lock_guard<std::mutex> lock(processImageMutex);
            if (bufferToProcess) {
                wasDiscarded = true;
                bufferToProcess->push(*this);
            }
            bufferToProcess.swap(buffer);
        }
        processImageCV.notify_one();
        {
            std::lock_guard<std::mutex> lock(statisticsMutex);
            if (wasDiscarded) {
                ++statisticsDiscardedBufferCount;
            }
            ++statisticsBufferCount;
        }
    }

    void processImage() {
        std::unique_ptr<Buffer> buffer;
        {
            std::unique_lock<std::mutex> lock(processImageMutex);
            processImageCV.wait_for(lock, std::chrono::milliseconds(100));
            if (bufferToProcess) {
                bufferToProcess.swap(buffer);
            }
        }
        if (buffer) {
            uint8_t *bufferPtr = buffer->getInfo<uint8_t *>(*this, gc::BUFFER_INFO_BASE);
            uint64_t pixelFormat = buffer->getInfo<uint64_t>(*this, gc::BUFFER_INFO_PIXELFORMAT);
            size_t imageWidth = buffer->getInfo<size_t>(*this, gc::BUFFER_INFO_WIDTH);
            size_t imageHeight = buffer->getInfo<size_t>(*this, gc::BUFFER_INFO_DELIVERED_IMAGEHEIGHT);
            std::unique_ptr<FormatConverter::Auto> dataToProcess(new FormatConverter::Auto(converter, FormatConverter::OutputFormat("RGB8"),
                bufferPtr, pixelFormat, imageWidth, imageHeight));
            window.updateImage(dataToProcess->getBuffer(), dataToProcess->getBufferSize());
            buffer->push(*this);
        }
    }

    void updateStatistics() {
        std::chrono::steady_clock::time_point initialStatisticsTimestamp = std::chrono::steady_clock::now();
        while (getInfo<StreamModule, bool>(gc::STREAM_INFO_IS_GRABBING)) {
            uint64_t statisticsProcessedBufferCount = 0;
            uint64_t timeDifferenceMS = 0;
            {
                std::lock_guard<std::mutex> lock(statisticsMutex);
                statisticsProcessedBufferCount = statisticsBufferCount - statisticsDiscardedBufferCount;
                totalBufferCount += statisticsBufferCount;
                totalDiscardedBufferCount += statisticsDiscardedBufferCount;
                statisticsBufferCount = 0;
                statisticsDiscardedBufferCount = 0;
                
                std::chrono::steady_clock::time_point now = std::chrono::steady_clock::now();
                timeDifferenceMS = std::chrono::duration_cast<std::chrono::milliseconds>(now - initialStatisticsTimestamp).count();
                initialStatisticsTimestamp = now;
            }

            if (timeDifferenceMS > 0) {
                std::stringstream ss;
                ss << "eGrabber sample: displayLatestBuffer";
                double fps = statisticsProcessedBufferCount * 1000.f / timeDifferenceMS;
                ss << " - " << totalBufferCount << " processed buffers";
                ss << " (" << totalDiscardedBufferCount << " discarded buffers)";
                ss << " - " << std::setprecision(2) << std::fixed << fps << " fps";
                std::cout << ss.str() << std::endl;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(1000));
        }
    }

    FormatConverter converter;
    uint64_t totalBufferCount;
    uint64_t totalDiscardedBufferCount;
    uint64_t statisticsBufferCount;
    uint64_t statisticsDiscardedBufferCount;
    std::mutex processImageMutex;
    std::mutex statisticsMutex;
    std::unique_ptr<Buffer> bufferToProcess;
    std::condition_variable processImageCV;
    Window window;
};


int main(int argc, char* argv[]) {
    try {
        EGenTL genTL;
        MyGrabber grabber(genTL);
        grabber.go();
        return 0;
    } catch (const std::exception &e) {
        std::cerr << e.what() << std::endl;
        return 1;
    } catch (...) {
        std::cerr << "uncaught exception!" << std::endl;
        return 1;
    }
}
