#include <cuda_runtime.h>
#include "device_launch_parameters.h"

#include "502-grabn-cuda-copy-and-process.h"

__global__ void
extractMaxLuminance502(unsigned char *cudaFrameBuffer, size_t bufferSize, unsigned char *cudaBuffer, size_t bufferNumber) {
    size_t index = blockIdx.x * blockDim.x + threadIdx.x;
    unsigned char *indexPixelReserve = cudaBuffer + index;
    unsigned char *indexPixelInput = cudaFrameBuffer + index;
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
extractMinLuminance502(unsigned char *cudaFrameBuffer, size_t bufferSize, unsigned char *cudaBuffer, size_t bufferNumber) {
    size_t index = blockIdx.x * blockDim.x + threadIdx.x;
    unsigned char *indexPixelReserve = cudaBuffer + index;
    unsigned char *indexPixelInput = cudaFrameBuffer + index;
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
superpose502(unsigned char *cudaFrameBuffer, size_t bufferSize, unsigned char *cudaBuffer, size_t bufferNumber) {
    size_t index = blockIdx.x * blockDim.x + threadIdx.x;
    unsigned char *indexPixelReserve = cudaBuffer + index;
    unsigned char *indexPixelInput = cudaFrameBuffer + index;
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
subtract502(unsigned char *cudaFrameBuffer, size_t bufferSize, unsigned char *cudaBuffer, size_t bufferNumber) {
    size_t index = blockIdx.x * blockDim.x + threadIdx.x;
    unsigned char *indexPixelReserve = cudaBuffer + index;
    unsigned char *indexPixelInput = cudaFrameBuffer + index;
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

unsigned char* ProcessingImage502(std::vector<unsigned char *> &cudaFrameBuffers, int numBuffers, unsigned char *cudaBuffer, size_t bufferSize, size_t frame, int method) {
    unsigned char *resultBuffer = 0;
    int bdim = NB_CUDA_THREADS;
    int gdim = (static_cast<int>(bufferSize) + bdim - 1) / bdim;
    if (method == MAX_LUMINANCE) {
        for (int i = 0; i < numBuffers; i++) {
            extractMaxLuminance502 << < gdim, bdim >> > (cudaFrameBuffers[i], bufferSize, cudaBuffer, i);
        }
    } else if (method == MIN_LUMINANCE) {
        for (int i = 0; i < numBuffers; i++) {
            extractMinLuminance502 << < gdim, bdim >> > (cudaFrameBuffers[i], bufferSize, cudaBuffer, i);
        }
    } else if (method == SUPERPOSE) {
        for (int i = 0; i < numBuffers; i++) {
            superpose502 << < gdim, bdim >> > (cudaFrameBuffers[i], bufferSize, cudaBuffer, i);
        }
    } else if (method == SUBTRACT) {
        for (int i = 0; i < numBuffers; i++) {
            subtract502 << < gdim, bdim >> > (cudaFrameBuffers[i], bufferSize, cudaBuffer, i);
        }
    }
    check(cudaDeviceSynchronize());
    check(cudaMallocHost((void **)&resultBuffer, bufferSize));
    check(cudaMemcpy(resultBuffer, cudaBuffer, bufferSize, cudaMemcpyDeviceToHost));
    check(cudaDeviceSynchronize());
    return resultBuffer;
}
