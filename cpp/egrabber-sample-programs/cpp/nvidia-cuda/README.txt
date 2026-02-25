egrabber-cuda sample program

This sample illustrates interoperability of EGrabber, OpenGL and CUDA:
- Acquisition of 8-bit monochrome buffers using EGrabber
- Basic processing with CUDA (Inverse 8-bit luminance)
- Rendering with OpenGL (Rotate with click and drag)

Preliminary notes:
- This sample requires the CUDA Toolkit
- It has been built and tested with CUDA Toolkits 8.0, 9.0, 10.0 and 11.0
- The CUDA Toolkit can be downloaded from the following link:
  https://developer.nvidia.com/cuda-downloads
- For Ubuntu/Debian, it might be necessary to install the following packages
  (besides the CUDA toolkit):
    - libglew-dev
    - freeglut3-dev
    - nvidia-cuda-dev
    - nvidia-cuda-toolkit

The main steps of the sample code are:
- Init the grabber
- Init OpenGL
- Init CUDA (find device and initialize it to inter-operate with OpenGL)
- Without cudaRDMA option: allocate pinned memory (allocated by cudaHostMalloc)
  and announce it for use with the grabber using UserMemory
- With cudaRDMA option: allocate GPU memory (allocated by cudaMalloc)
  and announce it for use with the grabber using NvidiaRdmaMemory
- Start EGrabber -> spawn a thread that waits for a buffer
- Setup OpenGL object texture (create a quad, create a texture)
- Setup CUDA resource (allocate a buffer in GPU and register texture to be used
  by CUDA)
- Registered display callback calls update texture
- Main loop

Update texture:
- Take the current grabbed buffer
- Perform DMA copy from pinned host memory into GPU buffer (6 GB/s) unless cudaRDMA option
  is enabled (in this case there is no copy involved because host memory has not been used
  to acquire data)
- Launch CUDA kernel threads (in this sample: 1024 threads and
  image_size/1024/2 blocks)
- CUDA Kernel inverse luminance of 2 pixels
- CUDA device sync
- Perform intra GPU copy of buffer to texture buffer (14 GB/s)
