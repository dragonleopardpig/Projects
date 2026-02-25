"""Allocate an eGrabber buffer mapped into the CUDA device memory and run a kernel to invert its luminance values"""

from egrabber import *
from cuda_helpers import *
from cuda.bindings import runtime as cudart
import ctypes

kernel_invert_image_code = """
extern "C" __global__ void invertImage(void *pinnedHostFrameBuffer, size_t bufferSize, void *resultBuffer) {
    size_t index = blockIdx.x * blockDim.x + threadIdx.x;
    if (index < bufferSize) {
        unsigned char *indexPixelInput = (unsigned char *) pinnedHostFrameBuffer + index;
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
count = cuda.cudaGetDeviceCount()
if count < 1:
    print('No CUDA device found, exiting')
    exit(1)
cuda_device = 0
cuda.cudaSetDevice(cuda_device)
device_prop = cuda.cudaGetDeviceProperties(cuda_device)
if not device_prop.canMapHostMemory:
    print('CUDA device does not support mapping CPU host memory!')
    exit(1)
cuda.cudaSetDeviceFlags(cuda.cudaDeviceMapHost)

print('Announcing buffers')
pinned_memory = cuda.cudaHostAlloc(buffer_size, cuda.cudaHostAllocMapped)
byte_array = (ctypes.c_char * buffer_size).from_address(pinned_memory)
grabber.announce_and_queue(UserMemory(byte_array))

# Obtain a buffer into pinned_memory
print('Starting acquisition')
grabber.start(1)
with Buffer(grabber) as buffer:
    pass
grabber.stop()
print('Stopping acquisition')

input_params = ImageConvertInput(buffer_width, buffer_height, byte_array, pixel_format, buffer_size, buffer_pitch)
gentl.image_save_to_disk(input_params, 'input_frame.bmp')

result_buffer = cuda.cudaHostAlloc(buffer_size, cuda.cudaHostAllocMapped)
result_buffer_data = (ctypes.c_ubyte * buffer_size).from_address(result_buffer)

# Process the buffer with CUDA
print('Launching kernel')
bdim = 1024
gdim = (buffer_size + bdim - 1) / bdim
kernel_params = ((pinned_memory, buffer_size, result_buffer),
                 (ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p))
cuda_build_and_launch_kernel(cuda_device, kernel_invert_image_code, "invertImage", bdim, gdim, kernel_params)
cuda.cudaDeviceSynchronize()

input_params = ImageConvertInput(buffer_width, buffer_height, result_buffer_data, pixel_format, buffer_size, buffer_pitch)
gentl.image_save_to_disk(input_params, 'output_frame.bmp')

print('Finished')

cuda.cudaFreeHost(pinned_memory)
cuda.cudaFreeHost(result_buffer)
cuda.cudaDeviceReset()
