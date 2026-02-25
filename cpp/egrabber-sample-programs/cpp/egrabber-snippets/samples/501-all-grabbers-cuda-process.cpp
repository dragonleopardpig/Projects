#include "501-all-grabbers-cuda-process.h"
#include "../tools/tools.h"
#include <cuda.h>

using namespace Euresys;

namespace {

struct EnsureNullItem {
    void operator() (unsigned char *ptr) {
        if (ptr) { throw std::runtime_error("pinnedMemory items should all be NULL"); }
    }
};

struct FreeHost {
    void operator() (unsigned char *ptr) { cudaFreeHost(ptr); }
};

class MyEGrabber: public EGrabberCallbackSingleThread {
public:
    MyEGrabber(const EGrabberInfo &grabber)
    : EGrabberCallbackSingleThread(grabber)
    , accomplished(false)
    , interfaceIndex(grabber.interfaceIndex)
    , deviceIndex(grabber.deviceIndex)
    , streamIndex(grabber.streamIndex)
    , frame(0)
    , ptrBuffer(NULL)
    , bufferSize(0)
    {
        pinnedMemory = std::vector<unsigned char *>(NUM_IMAGE);
        runScript(Tools::getSampleFilePath("501-all-grabbers-cuda-process.setup.js"));
        checkFormat();
        bufferSize = getWidth() * getHeight();
        check(cudaMalloc((void **)&ptrBuffer, bufferSize));
        try {
            allocateAndAnnounceBuffers();
        } catch (...) {
            shutdown();
            releaseBuffers();
            cudaFree(ptrBuffer);
            throw;
        }
    };
    ~MyEGrabber() {
        shutdown();
        releaseBuffers();
        cudaFree(ptrBuffer);
    };
    void go(size_t numImages) {
        start(numImages);
    }
    void stopGrab() {
        disableEvent<All>();
        stop();
        accomplished = true;
    }
    void runCudaProcessing(int method) {
        unsigned char *resultBuffer = 0;
        try{
            resultBuffer = ProcessingImage501(pinnedHostFrameBuffers, NUM_IMAGE, ptrBuffer, bufferSize, NUM_IMAGE, method);
            size_t linePitch = 0;
            ge::ImageConvertInput input = IMAGE_CONVERT_INPUT(
                (int)getWidth(),
                (int)getHeight(),
                resultBuffer,
                "Mono8",
                &bufferSize,
                &linePitch
            );
            const std::string path = "output/501-sample/";
            std::string file = path + Tools::toString(interfaceIndex) + Tools::toString(deviceIndex) + Tools::toString(streamIndex) + ".jpeg";
            getGenTL().imageSaveToDisk(input, file);
            Tools::log("Grabber: <Interface>[" + Tools::toString(interfaceIndex) + "]<Device>["
                      + Tools::toString(deviceIndex) + "]<DataStream>[" + Tools::toString(streamIndex) + "] CUDA processing finished");
        } catch(...) {
            Tools::log("runCudaProcessing failed.");
            cudaFree(resultBuffer);
            throw;
        }
        cudaFree(resultBuffer);
    }
    void releaseBuffers() {
        FreeHost freeHost;
        std::for_each(pinnedMemory.begin(), pinnedMemory.end(), freeHost);
    }
    bool accomplished;
private:
    virtual void onNewBufferEvent(const NewBufferData& data) {
        Buffer buffer(data);
        pinnedHostFrameBuffers[frame] = (unsigned char *)buffer.getUserPointer();
        if (++frame >= NUM_IMAGE) {
            stopGrab();
        }
    }
    void allocateAndAnnounceBuffers() {
        EnsureNullItem ensureNullItem;
        std::for_each(pinnedMemory.begin(), pinnedMemory.end(), ensureNullItem);
        size_t size = getWidth() * getHeight();
        for (size_t i = 0; i < pinnedMemory.size(); ++i) {
            unsigned char *ptr, *devicePtr;
            check(cudaHostAlloc(&ptr, size, cudaHostAllocMapped));
            pinnedMemory[i] = ptr;
            check(cudaHostGetDevicePointer(&devicePtr, ptr, 0));
            announceAndQueue(UserMemory(ptr, size, devicePtr));
        }
    }
    void checkFormat() {
        if (getPixelFormat() != "Mono8") {
            throw std::runtime_error("This sample only works for Mono8 PixelFormat");
        }
    }
    int interfaceIndex, deviceIndex, streamIndex, frame;
    unsigned char* ptrBuffer, *pinnedHostFrameBuffers[NUM_IMAGE];
    std::vector<unsigned char *> pinnedMemory;
    size_t bufferSize;
};

void cleanupCuda() {
    check(cudaDeviceReset());
}

void initCuda() {
    cleanupCuda();
    int device = 0;
    cudaDeviceProp prop = { 0 };
    check(cudaGetDeviceProperties(&prop, device));
    if (prop.maxThreadsPerBlock < NB_CUDA_THREADS) {
        throw std::runtime_error("CUDA device has not enough threads per block");
    }
    if (!prop.canMapHostMemory) {
        throw std::runtime_error("CUDA device cannot map host memory");
    }
#if CUDA_VERSION < 13000
    if (!prop.deviceOverlap) {
#else
    if (prop.asyncEngineCount <= 0) {
#endif
        throw std::runtime_error("CUDA device cannot copy memory between host and device while executing a kernel");
    }
    check(cudaSetDevice(device));
}

}

static void sample() {
    int method;
    Tools::log("Choose processing method\n[1]MAX_LUMINANCE, [2]MIN_LUMINANCE, [3]SUPERPOSE, [4]SUBTRACT");
    std::cin >> method;
    if (method > 4 || method < 1) {
        Tools::log("Wrong parameter, program aborted.");
        return;
    }
    EGenTL genTL;
    std::vector<MyEGrabber *> myEGrabbers;
    try {
        initCuda();
        EGrabberDiscovery discovery(genTL);
        discovery.discover(false);
        for (int ifIx = 0; ifIx < discovery.interfaceCount(); ++ifIx) {
            for (int devIx = 0; devIx < discovery.deviceCount(ifIx); ++devIx) {
                myEGrabbers.push_back(new MyEGrabber(discovery.streamInfo(ifIx, devIx, 0)));
            }
        }
        for (size_t grabberIndex = 0; grabberIndex < myEGrabbers.size(); ++grabberIndex) {
            if (myEGrabbers[grabberIndex]) {
                myEGrabbers[grabberIndex]->go(NUM_IMAGE);
            }
        }
        do {
            bool finished = true;
            for (size_t grabberIndex = 0; grabberIndex < myEGrabbers.size(); ++grabberIndex) {
                if (myEGrabbers[grabberIndex]) {
                    finished &= myEGrabbers[grabberIndex]->accomplished;
                }
            }
            if (finished) break;
            Tools::sleepMs(100);
        } while (true);
        for (size_t grabberIndex = 0; grabberIndex < myEGrabbers.size(); ++grabberIndex) {
            if (myEGrabbers[grabberIndex]) {
                myEGrabbers[grabberIndex]->runCudaProcessing(method);
            }
        }
    }
    catch (const std::exception &e) {
        std::cerr << e.what() << std::endl;
    }
    catch (...) {
        std::cerr << "uncaught exception!" << std::endl;
    }
    for (size_t grabberIndex = 0; grabberIndex < myEGrabbers.size(); ++grabberIndex) {
        delete myEGrabbers[grabberIndex];
    }
    cleanupCuda();
}

static Tools::Sample addSample(__FILE__, sample, "Use all available interfaces and devices to grab N frames and process them with CUDA operation");
