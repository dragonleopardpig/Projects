#ifndef CUDA_SAMPLE_HEADER_FILE
#define CUDA_SAMPLE_HEADER_FILE

#include <cstddef> // size_t

#define NB_CUDA_THREADS 1024

void cudaProcessBuffer(unsigned char *data, size_t size);

#endif
