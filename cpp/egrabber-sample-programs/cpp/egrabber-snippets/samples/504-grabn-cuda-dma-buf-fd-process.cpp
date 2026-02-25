#include "../tools/tools.h"
#include <EGrabber.h>

#include <cuda_runtime.h>
#include <cuda.h>

#if defined(linux) || defined(__linux) || defined(__linux__)
#include <unistd.h>

#include "504-grabn-cuda-dma-buf-fd-process.h"

using namespace Euresys;

namespace {

const int DEVICE = 0;

struct EnsureNullItem {
    void operator() (unsigned char *ptr) {
        if (ptr) { throw std::runtime_error("deviceMemory items should all be NULL"); }
    }
};

struct FreeDevice {
    void operator() (unsigned char *ptr) { cudaFree(reinterpret_cast<void*>(ptr)); }
};

struct CloseFd {
    void operator() (int fd) { close(fd); }
};

template <typename T>
class PageAligner {
public:
    PageAligner(void *origPointer, size_t origSize) {
	T devicePointer = (T)origPointer;
        const size_t pageSize = sysconf(_SC_PAGE_SIZE);
        alignedPointer = (T)((size_t)devicePointer & ~(pageSize - 1));
        offset = static_cast<unsigned int>(devicePointer - alignedPointer);
        alignedSize = (origSize + offset + pageSize - 1) & ~(pageSize - 1);
    }
    T getPointer() const { return alignedPointer; }
    size_t getSize() const { return alignedSize; }
    unsigned int getOffset() const { return offset; }
private:
    T alignedPointer;
    size_t alignedSize;
    unsigned int offset;
};

typedef PageAligner<CUdeviceptr> CudaPageAligner;

class MyGrabber: public EGrabberCallbackOnDemand {
public:
    MyGrabber(const EGrabberInfo &grabberInfo) : EGrabberCallbackOnDemand(grabberInfo), frame(0) {
        runScript(Tools::getSampleFilePath("504-grabn-cuda-dma-buf-fd-process.setup.js"));
    };
    ~MyGrabber() {};

    int frame;
    void go() {
        Tools::log("Processing images...");
        start(NUM_IMAGE);
        for (frame = 0; frame < NUM_IMAGE; frame++) {
            Buffer buffer(pop());
        }
        stop();
    }
};

void initCuda() {
    cudaDeviceProp prop = { 0 };
    check(cudaGetDeviceProperties(&prop, DEVICE));
    if (prop.maxThreadsPerBlock < NB_CUDA_THREADS) {
        throw std::runtime_error("CUDA device has not enough threads per block");
    }
    if (!prop.canMapHostMemory) {
        throw std::runtime_error("CUDA device cannot map host memory");
    }
    int isDmaBufSupported = 0;
#if CUDART_VERSION >= 11030
    int driverVersion;
    if (CUDA_SUCCESS != cuDriverGetVersion(&driverVersion)) {
        throw std::runtime_error("Could not get CUDA driver version");
    }
    if (driverVersion > 11030) {
        if (CUDA_SUCCESS != cuDeviceGetAttribute(&isDmaBufSupported, CU_DEVICE_ATTRIBUTE_DMA_BUF_SUPPORTED, DEVICE)) {
            throw std::runtime_error("Could not get device attribute");
        }
    }
#endif
    if (!isDmaBufSupported) {
        throw std::runtime_error("DMA-BUF is not supported");
    }
    check(cudaSetDevice(DEVICE));
}

void allocateAndAnnounceBuffers(MyGrabber &grabber, std::vector<unsigned char *> &deviceMemory, std::vector<int> &deviceMemoryHandles) {
    EnsureNullItem ensureNullItem;
    std::for_each(deviceMemory.begin(), deviceMemory.end(), ensureNullItem);
    size_t size = grabber.getWidth() * grabber.getHeight();
    for (size_t i = 0; i < deviceMemory.size(); ++i) {
        unsigned char *devicePtr;
        check(cudaMalloc(&devicePtr, size));
        deviceMemory[i] = devicePtr;
        int dmaBufFd = -1;
        int cuFlags = 0;
        CUmemRangeHandleType cudaHandleType = CU_MEM_RANGE_HANDLE_TYPE_DMA_BUF_FD;
        CudaPageAligner aligner(devicePtr, size);
        CUresult err = cuMemGetHandleForAddressRange((void *)&dmaBufFd, aligner.getPointer(), aligner.getSize(), cudaHandleType, cuFlags);
        if (CUDA_SUCCESS != err) {
            throw std::runtime_error("cuMemGetHandleForAddressRange failed");
        }
        deviceMemoryHandles[i] = dmaBufFd;
        unsigned int flag = 1;
        CUresult status = cuPointerSetAttribute(&flag, CU_POINTER_ATTRIBUTE_SYNC_MEMOPS, reinterpret_cast<CUdeviceptr>(deviceMemory[i]));
        if (CUDA_SUCCESS != status) {
            throw std::runtime_error("cuPointerSetAttribute failed");
        }
        grabber.announceAndQueue(DmaBufMemory(dmaBufFd, size, aligner.getOffset()));
    }
}

void releaseBufferHandles(std::vector<int> &deviceMemoryHandles) {
    CloseFd closeFd;
    std::for_each(deviceMemoryHandles.begin(), deviceMemoryHandles.end(), closeFd);
}

void releaseBuffers(std::vector<unsigned char *> &deviceMemory) {
    FreeDevice freeDevice;
    std::for_each(deviceMemory.begin(), deviceMemory.end(), freeDevice);
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
    std::vector<unsigned char *>deviceMemory(NUM_IMAGE);
    std::vector<int>deviceMemoryHandles(NUM_IMAGE, -1);
    Tools::log("Choice processing method\n[1]MAX_LUMINANCE, [2]MIN_LUMINANCE, [3]SUPERPOSE, [4]SUBTRACT");
    std::cin >> method;
    if (method > 4 || method < 1) {
        Tools::log("Wrong parameter, program aborted.");
        return;
    }
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
        allocateAndAnnounceBuffers(grabber, deviceMemory, deviceMemoryHandles);
        grabber.go();
        resultBuffer = ProcessingImage504(&deviceMemory[0], NUM_IMAGE, cudaBuffer, bufferSize, grabber.frame, method);
        size_t linePitch = 0;
        ge::ImageConvertInput input = IMAGE_CONVERT_INPUT(
            (int)grabber.getWidth(),
            (int)grabber.getHeight(),
            resultBuffer,
            "Mono8",
            &bufferSize,
            &linePitch
        );
        grabber.getGenTL().imageSaveToDisk(input, "output/504-sample/transferred_image.jpeg");
    } catch (const std::exception &e) {
        std::cerr << e.what() << std::endl;
    } catch (...) {
        std::cerr << "uncaught exception!" << std::endl;
    }
    releaseBufferHandles(deviceMemoryHandles);
    releaseBuffers(deviceMemory);
    cudaFree(cudaBuffer);
    cudaFree(resultBuffer);
    cleanupCuda();
}

static Tools::Sample addSample(__FILE__, sample, "Grab N frames in the GPU memory with DMA-BUF fd and process them with CUDA operations");
#endif
