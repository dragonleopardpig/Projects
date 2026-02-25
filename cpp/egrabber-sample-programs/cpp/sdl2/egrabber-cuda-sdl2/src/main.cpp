#include <iostream>
#include <mutex>
#include <condition_variable>
#include <atomic>
#include <cuda_runtime.h>
#include <EGrabber.h>
#include <window.h>
#include "check.h"
#include "cuda_defines.h"

using namespace Euresys;

class CUDAEnvironment {
public:
    CUDAEnvironment() {
        int device = 0;
        cudaDeviceProp prop = { 0 };
        check(cudaGetDeviceProperties(&prop, device));
        if (prop.maxThreadsPerBlock < NB_CUDA_THREADS) {
            throw std::runtime_error("CUDA device has not enough threads per block");
        }
        if (!prop.canMapHostMemory) {
            throw std::runtime_error("CUDA device cannot map host memory");
        }
        check(cudaSetDevice(device));
        check(cudaSetDeviceFlags(cudaDeviceMapHost));
    }
    ~CUDAEnvironment() {
        cudaDeviceReset();
    }
};

class MyGrabber : public EGrabberCallbackMultiThread {
public:
    MyGrabber(EGenTL &gentl)
        : EGrabberCallbackMultiThread(gentl)
        , window(getWidth(), getHeight()) {
    }

    ~MyGrabber() {
        releaseBuffers();
        shutdown();
    }

    void allocateAndAnnounceBuffers() {
        size_t bufferSize = getPayloadSize();
        pinnedMemory.clear();
        pinnedMemory.resize(3);
        for (size_t i = 0; i < pinnedMemory.size(); ++i) {
            unsigned char *ptr;
            unsigned char *devicePtr;
            check(cudaHostAlloc(&ptr, bufferSize, cudaHostAllocMapped));
            check(cudaHostGetDevicePointer(&devicePtr, ptr, 0));
            pinnedMemory[i] = ptr;
            announceAndQueue(UserMemory(ptr, bufferSize, devicePtr));
        }
    }

    void releaseBuffers() {
        for (auto ptr : pinnedMemory) {
            check(cudaFreeHost(ptr));
        }
        pinnedMemory.clear();
    }

    void go() {
        runScript("./config.js");
        bufferToProcess.reset();
        allocateAndAnnounceBuffers();
        start();
        while (window.isAlive()) {
            processImage();
        }
        stop();
        releaseBuffers();
    }

private:
    virtual void onNewBufferEvent(const NewBufferData &data) {
        std::unique_ptr<Buffer> buffer(new Buffer(data));
        {
            std::lock_guard<std::mutex> lock(processImageMutex);
            if (bufferToProcess) {
                bufferToProcess->push(*this);
            }
            bufferToProcess.swap(buffer);
        }
        processImageCV.notify_one();
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
            size_t size = buffer->getInfo<size_t>(*this, gc::BUFFER_INFO_DATA_SIZE);
            unsigned char *devicePtr = (unsigned char *)buffer->getUserPointer();
            cudaProcessBuffer(devicePtr, size);
            window.updateImage(devicePtr, size);
            buffer->push(*this);
        }
    }
    std::vector<unsigned char *> pinnedMemory;
    std::mutex processImageMutex;
    std::unique_ptr<Buffer> bufferToProcess;
    std::condition_variable processImageCV;
    Window window;
};

int main() {
    try {
        CUDAEnvironment cudaEnvironment;
        EGenTL genTL;
        MyGrabber grabber(genTL);
        grabber.go();
        return 0;
    }
    catch (const std::exception &e) {
        std::cerr << e.what() << std::endl;
        return 1;
    }
    catch (...) {
        std::cerr << "uncaught exception!" << std::endl;
        return 1;
    }
}
