#include "../tools/tools.h"
#include <EGrabber.h>

#include <cuda_runtime.h>

#include "502-grabn-cuda-copy-and-process.h"

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

struct FreeCuda {
    void operator() (unsigned char *ptr) { cudaFree(ptr); }
};

class MyGrabber: public EGrabberCallbackOnDemand {
public:
    MyGrabber(const EGrabberInfo &grabberInfo) : EGrabberCallbackOnDemand(grabberInfo), frame(0) {
        runScript(Tools::getSampleFilePath("502-grabn-cuda-copy-and-process.setup.js"));
    };
    ~MyGrabber() {};

    int frame;
    unsigned char *buffersArray[NUM_IMAGE];
    void go() {
        Tools::log("Processing images...");
        start(NUM_IMAGE);
        for (frame = 0; frame < NUM_IMAGE; frame++) {
            Buffer buffer(pop());
            buffersArray[frame] = buffer.getInfo<uint8_t *>(*this, gc::BUFFER_INFO_BASE);
        }
        stop();
    }
};

void initCuda() {
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
}

void allocateAndAnnounceBuffers(MyGrabber &grabber, std::vector<unsigned char *> &pinnedMemory) {
    EnsureNullItem ensureNullItem;
    std::for_each(pinnedMemory.begin(), pinnedMemory.end(), ensureNullItem);
    size_t size = grabber.getWidth() * grabber.getHeight();
    for (size_t i = 0; i < pinnedMemory.size(); ++i) {
        unsigned char *ptr, *devicePtr;
        check(cudaHostAlloc(&ptr, size, cudaHostAllocMapped));
        pinnedMemory[i] = ptr;
        check(cudaHostGetDevicePointer(&devicePtr, ptr, 0));
        grabber.announceAndQueue(UserMemory(ptr, size, devicePtr));
    }
}

void releaseBuffers(std::vector<unsigned char *> &pinnedMemory) {
    FreeHost freeHost;
    std::for_each(pinnedMemory.begin(), pinnedMemory.end(), freeHost);
}

void releaseCudaBuffers(std::vector<unsigned char *> &cudaFrameBuffers) {
    FreeCuda freeCuda;
    std::for_each(cudaFrameBuffers.begin(), cudaFrameBuffers.end(), freeCuda);
}

void cleanupCuda() {
    cudaDeviceReset();
}

void showGrabberInfo(MyGrabber &grabber) {
    std::cout << "resolution:\t" << grabber.getWidth() << "x" << grabber.getHeight() << std::endl;
    std::cout << "pixel format:\t" << grabber.getPixelFormat() << std::endl;
}

void checkFormat(MyGrabber &grabber) {
    if (grabber.getPixelFormat() != "Mono8") {
        throw std::runtime_error("This sample only works for Mono8 PixelFormat");
    }
}

size_t getBufferSize(MyGrabber &grabber) {
    return grabber.getWidth()*grabber.getHeight();
}

}

static void sample() {
    int method = 0;
    unsigned char *cudaBuffer = 0;
    unsigned char *resultBuffer = 0;
    std::vector<unsigned char *>pinnedMemory(NUM_IMAGE);
    std::vector<unsigned char *>cudaFrameBuffers(NUM_IMAGE);
    Tools::log("Choose processing method\n[1]MAX_LUMINANCE, [2]MIN_LUMINANCE, [3]SUPERPOSE, [4]SUBTRACT");
    std::cin >> method;
    if (method > 4 || method < 1) {
        Tools::log("Wrong parameter, program aborted.");
        return;
    }

    int memoryType = 0;
    Tools::log("Choose memory type\n[1]Pinned memory, [2]Pageable memory");
    std::cin >> memoryType;
    if (memoryType > 2 || memoryType < 1) {
        Tools::log("Wrong parameter, program aborted.");
        return;
    }
    bool usePinnedMemory = (memoryType == 1);
    try {
        EGenTL genTL(Coaxlink());
        EGrabberDiscovery discovery(genTL);
        discovery.discover(false);
        if (discovery.egrabberCount() == 0) {
            Tools::log("No grabber, program aborted.");
            return;
        }
        MyGrabber grabber(discovery.egrabbers(0));

        checkFormat(grabber);
        showGrabberInfo(grabber);
        initCuda();
        size_t bufferSize = getBufferSize(grabber);
        check(cudaMalloc((void **)&cudaBuffer, bufferSize));

        if (usePinnedMemory) {
            allocateAndAnnounceBuffers(grabber, pinnedMemory);
        } else {
            grabber.reallocBuffers(NUM_IMAGE, bufferSize);
        }
        grabber.go();

        for (int i = 0; i < NUM_IMAGE; ++i) {
            check(cudaMalloc((void **)&cudaFrameBuffers[i], bufferSize));
            check(cudaMemcpy(cudaFrameBuffers[i], grabber.buffersArray[i], bufferSize, cudaMemcpyHostToDevice));
        }

        resultBuffer = ProcessingImage502(cudaFrameBuffers, NUM_IMAGE, cudaBuffer, bufferSize, grabber.frame, method);
        size_t linePitch = 0;
        ge::ImageConvertInput input = IMAGE_CONVERT_INPUT(
            (int)grabber.getWidth(),
            (int)grabber.getHeight(),
            resultBuffer,
            "Mono8",
            &bufferSize,
            &linePitch
        );
        grabber.getGenTL().imageSaveToDisk(input, "output/502-sample/transferred_image.jpeg");
    } catch (const std::exception &e) {
        std::cerr << e.what() << std::endl;
    } catch (...) {
        std::cerr << "uncaught exception!" << std::endl;
    }
    if (usePinnedMemory) {
        releaseBuffers(pinnedMemory);
    }
    releaseCudaBuffers(cudaFrameBuffers);
    cudaFree(cudaBuffer);
    cudaFree(resultBuffer);
    cleanupCuda();
}

static Tools::Sample addSample(__FILE__, sample, "Grab N frames, copy the buffers to the CUDA device and process them with CUDA operations");
