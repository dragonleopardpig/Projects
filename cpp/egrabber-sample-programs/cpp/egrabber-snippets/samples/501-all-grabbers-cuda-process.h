#pragma once
#include <algorithm>
#include "../tools/tools.h"

#include <cuda_runtime.h>

#define NUM_IMAGE 10

#define NB_CUDA_THREADS 1024

#define MAX_LUMINANCE 1
#define MIN_LUMINANCE 2
#define SUPERPOSE     3
#define SUBTRACT      4

#define check(e) do { checkAndThrow((e), #e, __FILE__, __LINE__); } while (0)

namespace {

    void checkAndThrow(const cudaError_t e, const char *call, const char *filename, int line) {
        if (e != cudaSuccess) {
            std::ostringstream message;
            message << call << " failed: " << cudaGetErrorString(e) << ", " << filename << ": " << line;
            throw std::runtime_error(message.str());
        }
    }

}

unsigned char* ProcessingImage501(unsigned char *pinnedHostFrameBuffers[], int numBuffers, unsigned char *cudaBuffer, size_t bufferSize, size_t frame, int method);
