#include <cuda_runtime.h>
#include "device_launch_parameters.h"

#include "500-grabn-cuda-process.h"

__global__ void
extractMaxLuminance500(unsigned char *pinnedHostFrameBuffer, size_t bufferSize, unsigned char *cudaBuffer, size_t bufferNumber) {
    size_t index = blockIdx.x * blockDim.x + threadIdx.x;
    unsigned char *indexPixelReserve = cudaBuffer + index;
    unsigned char *indexPixelInput = pinnedHostFrameBuffer + index;
    if (index < bufferSize) {
        if (bufferNumber == 0) {
            *indexPixelReserve = *indexPixelInput;
        } else {
            if (*indexPixelInput > *indexPixelReserve) {
                *indexPixelReserve = *indexPixelInput;
            }
        }
    }
}

__global__ void
extractMinLuminance500(unsigned char *pinnedHostFrameBuffer, size_t bufferSize, unsigned char *cudaBuffer, size_t bufferNumber) {
    size_t index = blockIdx.x * blockDim.x + threadIdx.x;
    unsigned char *indexPixelReserve = cudaBuffer + index;
    unsigned char *indexPixelInput = pinnedHostFrameBuffer + index;
    if (index < bufferSize) {
        if (bufferNumber == 0) {
            *indexPixelReserve = *indexPixelInput;
        } else {
            if (*indexPixelInput < *indexPixelReserve) {
                *indexPixelReserve = *indexPixelInput;
            }
        }
    }
}

__global__ void
superpose500(unsigned char *pinnedHostFrameBuffer, size_t bufferSize, unsigned char *cudaBuffer, size_t bufferNumber) {
    size_t index = blockIdx.x * blockDim.x + threadIdx.x;
    unsigned char *indexPixelReserve = cudaBuffer + index;
    unsigned char *indexPixelInput = pinnedHostFrameBuffer + index;
    if (index < bufferSize) {
        if (bufferNumber == 0) {
            *indexPixelReserve = *indexPixelInput;
        } else {
            if ((*indexPixelReserve + *indexPixelInput) > 255) {
                *indexPixelReserve = 255;
            } else {
                *indexPixelReserve += *indexPixelInput;
            }
        }
    }
}

__global__ void
subtract500(unsigned char *pinnedHostFrameBuffer, size_t bufferSize, unsigned char *cudaBuffer, size_t bufferNumber) {
    size_t index = blockIdx.x * blockDim.x + threadIdx.x;
    unsigned char *indexPixelReserve = cudaBuffer + index;
    unsigned char *indexPixelInput = pinnedHostFrameBuffer + index;
    if (index < bufferSize) {
        if (bufferNumber == 0) {
            *indexPixelReserve = *indexPixelInput;
        } else {
            if ((*indexPixelReserve - *indexPixelInput) < 0) {
                *indexPixelReserve = 0;
            } else {
                *indexPixelReserve -= *indexPixelInput;
            } 
        }
    }
}

unsigned char* ProcessingImage500(unsigned char *pinnedHostFrameBuffers[], int numBuffers, unsigned char *cudaBuffer, size_t bufferSize, size_t frame, int method) {
    unsigned char *resultBuffer = 0;
    int bdim = NB_CUDA_THREADS;
    int gdim = (static_cast<int>(bufferSize) + bdim - 1) / bdim;
    if (method == MAX_LUMINANCE) {
        for (int i = 0; i < numBuffers; i++) {
            extractMaxLuminance500 << < gdim, bdim >> > (pinnedHostFrameBuffers[i], bufferSize, cudaBuffer, i);
        }
    } else if (method == MIN_LUMINANCE) {
        for (int i = 0; i < numBuffers; i++) {
            extractMinLuminance500 << < gdim, bdim >> > (pinnedHostFrameBuffers[i], bufferSize, cudaBuffer, i);
        }
    } else if (method == SUPERPOSE) {
        for (int i = 0; i < numBuffers; i++) {
            superpose500 << < gdim, bdim >> > (pinnedHostFrameBuffers[i], bufferSize, cudaBuffer, i);
        }
    } else if (method == SUBTRACT) {
        for (int i = 0; i < numBuffers; i++) {
            subtract500 << < gdim, bdim >> > (pinnedHostFrameBuffers[i], bufferSize, cudaBuffer, i);
        }
    }
    check(cudaDeviceSynchronize());
    check(cudaMallocHost((void **)&resultBuffer, bufferSize));
    check(cudaMemcpy(resultBuffer, cudaBuffer, bufferSize, cudaMemcpyDeviceToHost));
    check(cudaDeviceSynchronize());
    return resultBuffer;
}
