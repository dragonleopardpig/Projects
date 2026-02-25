"""Allocate eGrabber buffers directly in a CUDA device memory using eGrabber NvidiaRdmaMemory"""

from egrabber import *
from cuda_helpers import *
from cuda.bindings import runtime as cudart
import numpy as np

kernel_invert_image_code = """
extern "C" __global__ void invertImage(void *inputBuffer, size_t bufferSize, void *resultBuffer) {
    size_t index = blockIdx.x * blockDim.x + threadIdx.x;
    if (index < bufferSize) {
        unsigned char *indexPixelInput = (unsigned char *) inputBuffer + index;
        unsigned char *indexPixelOutput = (unsigned char *) resultBuffer + index;
        *indexPixelOutput = 255 - *indexPixelInput;
    }
}
"""

print('Initializing grabber')
gentl = EGenTL()
grabber = EGrabber(gentl)
grabber.remote.set('PixelFormat', 'Mono8')
buffer_width = grabber.get_width()
buffer_height = grabber.get_height()
buffer_pitch = buffer_width
pixel_format = grabber.get_pixel_format()
buffer_size = grabber.get_payload_size()

print('Initializing CUDA')
cuda = Cuda(cudart)
cuda_driver = Cuda(driver)
count = cuda.cudaGetDeviceCount()
if count < 1:
    print('No CUDA device found, exiting')
    exit(1)
cuda.cudaSetDevice(0)

if not grabber.stream.get('MemoryTypeSupported[NvidiaRDMA]'):
    print('NVIDIA RDMA environment is not available')
    exit(1)

buffer_count = 5
print(f'Announcing {buffer_count} buffers')
buffer_size = grabber.get_payload_size()
for _ in range(buffer_count):
    cuda_ptr = cuda.cudaMalloc(buffer_size)
    nvidia_memory = NvidiaRdmaMemory(cuda_ptr, buffer_size, cuda_ptr)
    grabber.announce_and_queue(nvidia_memory)

print('Pop buffers and store their references')
cuda_ptrs = []
grabber.start(buffer_count)
for i in range(buffer_count):
    with Buffer(grabber) as buffer:
        cuda_ptr = buffer.get_user_pointer()
        cuda_ptrs.append(cuda_ptr)

        # Save input buffer to disk (copying from device to host is required)
        dst = np.zeros(buffer_size, dtype=np.uint8)
        cuda.cudaMemcpy(dst, cuda_ptr, buffer_size, cuda.cudaMemcpyKind.cudaMemcpyDeviceToHost)
        c_char_array_type = ctypes.c_char * buffer_size
        c_char_array = c_char_array_type(*dst.tobytes())
        input_params = ImageConvertInput(buffer_width, buffer_height, c_char_array, pixel_format, buffer_size, buffer_pitch)
        gentl.image_save_to_disk(input_params, f'input_frame_{i}.bmp')
grabber.stop()

print(f'Building CUDA kernel')
cuda_module = cuda_build_kernel(cuda_driver, 0, kernel_invert_image_code)

for i in range(buffer_count):
    result_buffer = cuda.cudaHostAlloc(buffer_size, cuda.cudaHostAllocMapped)
    print(f'Launching kernel for buffer {i}')
    bdim = 1024
    gdim = (buffer_size + bdim - 1) / bdim
    kernel_params = ((cuda_ptrs[i], buffer_size, result_buffer),
                    (ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p))
    cuda_launch_kernel(cuda_driver, cuda_module, "invertImage", bdim, gdim, kernel_params)
    cuda.cudaDeviceSynchronize()

    # Save output buffer to disk
    input_params = ImageConvertInput(buffer_width, buffer_height, result_buffer, pixel_format, buffer_size, buffer_pitch)
    gentl.image_save_to_disk(input_params, f'output_frame_{i}.bmp')
print('Finished')

cuda_driver.cuModuleUnload(cuda_module)
for cuda_ptr in cuda_ptrs:
    cuda.cudaFree(cuda_ptr)
