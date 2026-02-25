extern "C" __global__ void
invertKernel(unsigned char *buffer, int bufferSize)
{
    int i = blockDim.x * blockIdx.x + threadIdx.x;
    if (i < bufferSize)
    {
        buffer[i] = 255 - buffer[i];
    }
}