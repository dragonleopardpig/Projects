#include <GL/glew.h>
#include <GL/freeglut.h>
#include <GL/gl.h>

#include <cuda_runtime.h>
#include <cuda_gl_interop.h>
#include <cuda_profiler_api.h>

#include "cuda.h"
#include "check.h"

__global__ void
cudaProcess(unsigned char *data, size_t size) {
    // Inverse 8-bit luminance of 2 pixels
    size_t x = blockIdx.x * blockDim.x + threadIdx.x;
    if ((x + 1) * 2 > size) {
        return;
    }
    unsigned char *p = data + 2 * x;
    *p = 255 - *p;
    ++p;
    *p = 255 - *p;
}

void cudaUpdateTexture(const UpdateParams &params) {
    int bdim = NB_CUDA_THREADS;
    int gdim = (static_cast<int>(params.size) + bdim - 1) / bdim;
    gdim = (gdim + 1) / 2; // 2 pixels per cuda kernel
    if (params.useHostMemory || params.useRDMA) {
        cudaProcess <<< gdim, bdim >>>(params.devicePtr, params.size);
    }
    else {
        check(cudaMemcpy(cudaMem, params.devicePtr, params.size, cudaMemcpyDeviceToDevice));
        cudaProcess <<< gdim, bdim >>>(cudaMem, params.size);
    }
    check(cudaDeviceSynchronize());
    if (params.useHostMemory || params.useRDMA) {
        check(cudaMemcpyToArray(cudaTexture, 0, 0, params.devicePtr, params.size, cudaMemcpyDeviceToDevice));
    }
    else {
        check(cudaMemcpyToArray(cudaTexture, 0, 0, cudaMem, params.size, cudaMemcpyDeviceToDevice));
    }
}
