egrabber-cuda-sdl2 sample program

This sample demonstrates the interoperability between eGrabber and CUDA.
RGB8 images are obtained from the framegrabber with eGrabber and then processed in a CUDA kernel.
Buffers are mapped into the address space of the CUDA device, allowing the CUDA kernel to directly
access the data and eliminating the need for explicit data copying.
Each CUDA thread processes one pixel, inversing the luminance of each of its three components.
The modified images are displayed in a SDL2 window.

Notes:
- This sample requires the CUDA Toolkit.
  The CUDA Toolkit can be downloaded from the following link: https://developer.nvidia.com/cuda-downloads
- This sample requires SDL2. The SDL2 libraries and headers are included in this package (Windows only).
  In Ubuntu/Debian systems, SDL2 can be installed with `sudo apt-get install libsdl2-dev`.
  Otherwise, they can be downloaded from the following link: https://github.com/libsdl-org/SDL/releases
- This sample was tested with CUDA 12 and CUDA 13, with the following compilers:
  - Windows: Microsoft Visual Studio 2019 and 2022.
  - Linux: GCC 11.4 and 13.3.
- Windows: if a different CUDA version is installed, the user can switch the version to use in Visual Studio by opening
  the Build Customizations dialog: right click on the project -> Build Dependencies -> Build Customizations.

The main steps of the sample code are:
- Initialize the CUDA environment by selecting the first device and enabling the mapping of host memory.
- Initialize the eGrabber object by taking the first coaxlink device found.
- Allocate and announce buffers. Buffers are allocated on the host and mapped into the CUDA device address space.
  The link between the host buffer address and its CUDA device address is stored in the Euresys::UserMemory class.
  The CUDA device can then directly access this memory to read and write data, without needing to copy the data back and forth.
- Start an infinite loop waiting for images. The method MyGrabber::processImage waits for a buffer.
  Once a buffer is available, it is processed in the CUDA kernel (cudaProcessBuffer) and displayed using SDL2 (Window::updateImage)
- When a buffer is received in MyGrabber::onNewBufferEvent, if the handling of the previous buffer has finished,
  it is marked to be the next to be processed. If the rate at which buffers are received is greater than the handling rate,
  only the latest buffer is processed and displayed. The rest are pushed back to the driver.
- In the end of the sample loop, everything is cleaned up and the memory is freed up.
