#include <cuda_runtime.h>
#include "cuda_defines.h"
#include "check.h"

__global__ void cudaProcess(unsigned char *data, size_t size) {
    // Inverse 8-bit luminance of a pixel (3 values)
    size_t x = blockIdx.x * blockDim.x + threadIdx.x;
    if ((x + 1) * 3 > size) {
        return;
    }
    unsigned char *p = data + 3 * x;
    for (int i = 0; i < 3; i++) {
        p[i] = 255 - p[i];
    }
}

void cudaProcessBuffer(unsigned char *data, size_t size) {
    // Process data in GPU
    int bdim = NB_CUDA_THREADS;
    int gdim = (static_cast<int>(size) + bdim * 3 - 1) / (bdim * 3);
    cudaProcess << < gdim, bdim >> > (data, size);
    check(cudaDeviceSynchronize());
}
