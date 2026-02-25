#ifndef CUDA_SAMPLE_HEADER_FILE
#define CUDA_SAMPLE_HEADER_FILE

#define NB_CUDA_THREADS 1024

struct UpdateParams {
    unsigned char *devicePtr;
    size_t size;
    bool useHostMemory;
    bool useRDMA;
};

extern unsigned char *cudaMem;
extern struct cudaGraphicsResource *texCudaResource;
extern cudaArray *cudaTexture;
void cudaUpdateTexture(const UpdateParams &params);

#endif
