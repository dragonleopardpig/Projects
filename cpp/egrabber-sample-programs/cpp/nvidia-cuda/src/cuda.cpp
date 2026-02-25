#include <iomanip>
#include <string>
#include <vector>
#include <map>
#include <algorithm>

#include <GL/glew.h>
#include <GL/freeglut.h>
#include <GL/gl.h>

#include <cuda_runtime.h>
#include <cuda_gl_interop.h>
#include <cuda_profiler_api.h>
#include <cuda.h>

#include <EGrabber.h>
#include "locks.h"

#include "egrabber-cuda.h"
#include "check.h"

using namespace Euresys;

unsigned char *cudaMem = 0;
struct cudaGraphicsResource *texCudaResource = 0;
cudaArray *cudaTexture = 0;

#define PROFILER(op) do { if (options[PROFILING]) { check(cudaProfiler##op()); } } while (0)

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
    check(cudaSetDeviceFlags(cudaDeviceMapHost));

#if CUDA_VERSION < 11000
    check(cudaGLSetGLDevice(device));
#endif
    glewInit();
}

void cleanupCuda() {
    cudaDeviceReset();
}

void allocateAndAnnounceBuffers(MyGrabber &grabber, std::vector<unsigned char *> &pinnedMemory) {
    struct EnsureNullItem {
        void operator() (unsigned char *ptr) {
            if (ptr) { throw std::runtime_error("pinnedMemory items should all be NULL"); }
        }
    } ensureNullItem;
    std::for_each(pinnedMemory.begin(), pinnedMemory.end(), ensureNullItem);
    size_t size = grabber.getWidth() * grabber.getHeight();
    for (size_t i = 0; i < pinnedMemory.size(); ++i) {
        unsigned char *ptr, *devicePtr;
        if (options[CUDA_RDMA]) {
            check(cudaMalloc(&ptr, size));
            unsigned int flag = 1;
            CUresult status = cuPointerSetAttribute(&flag, CU_POINTER_ATTRIBUTE_SYNC_MEMOPS, reinterpret_cast<CUdeviceptr>(ptr));
            if (CUDA_SUCCESS != status) {
                throw std::runtime_error("cuPointerSetAttribute failed");
            }
            devicePtr = ptr;
            pinnedMemory[i] = ptr;
            grabber.announceAndQueue(NvidiaRdmaMemory(ptr, size, devicePtr));
        } else {
            check(cudaHostAlloc(&ptr, size, cudaHostAllocMapped));
            check(cudaHostGetDevicePointer(&devicePtr, ptr, 0));
            pinnedMemory[i] = ptr;
            grabber.announceAndQueue(UserMemory(ptr, size, devicePtr));
        }
    }
}

void releaseBuffers(std::vector<unsigned char *> &pinnedMemory) {
    struct FreeHost {
        void operator() (unsigned char *ptr) {
            if (options[CUDA_RDMA]) {
                cudaFree(ptr);
            } else {
                cudaFreeHost(ptr);
            }
        }
    } freeHost;
    std::for_each(pinnedMemory.begin(), pinnedMemory.end(), freeHost);
}

void setupCudaResources(size_t width, size_t height, GLuint tex) {
    if (!options[CUDA_HOSTMEMORY]) {
        check(cudaMalloc((void **)&cudaMem, width * height * sizeof(GLubyte)));
    }
    check(cudaGraphicsGLRegisterImage(&texCudaResource, tex, GL_TEXTURE_2D, cudaGraphicsRegisterFlagsSurfaceLoadStore));
    check(cudaGraphicsMapResources(1, &texCudaResource, 0));
    check(cudaGraphicsSubResourceGetMappedArray(&cudaTexture, texCudaResource, 0, 0));
}

void cleanupCudaResources() {
    cudaGraphicsUnmapResources(1, &texCudaResource, 0);
    cudaGraphicsUnregisterResource(texCudaResource);
    cudaFree(cudaMem);
}

bool updateTexture() throw() {
    try {
        {
            Euresys::Sample::AutoLock autoLock(lock);
            if (!currentBuffer) {
                return true;
            }
        }
        PROFILER(Start);
        Buffer &buffer(*currentBuffer);
        const size_t size = buffer.getInfo<size_t>(*grabber, gc::BUFFER_INFO_DATA_SIZE);
        unsigned char *devicePtr = (unsigned char *)buffer.getUserPointer();
        bool useHostMemory = options[CUDA_HOSTMEMORY];
        bool useRDMA = options[CUDA_RDMA];
        UpdateParams params = { devicePtr, size, useHostMemory, useRDMA};
        cudaUpdateTexture(params);
        PROFILER(Stop);
        {
            Euresys::Sample::AutoLock autoLock(lock);
            currentBuffer->push(*grabber);
            delete currentBuffer;
            currentBuffer = 0;
        }
        return true;
    }
    catch (const std::exception &e) {
        std::cerr << e.what() << std::endl;
        return false;
    }
    catch (...) {
        std::cerr << "uncaught exception!" << std::endl;
        return false;
    }
}
