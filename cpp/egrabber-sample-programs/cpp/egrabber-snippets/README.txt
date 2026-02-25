egrabber-samples-cuda7.0 program 

Preliminary notes:
- This sample requires the CUDA Toolkik
- It has been built and tested with CUDA Toolkit 7.0
- The CUDA Toolkit can be downloaded from the following link:
  https://developer.nvidia.com/cuda-downloads
- For Ubuntu/Debian, it might be necessary to install the following packages
  (besides the CUDA toolkit):
    - nvidia-cuda-dev
    - nvidia-cuda-toolkit
- For CUDA Toolkit 7.0:
  For Visual Studio 2012 and 2013, the Microsoft project files should be automatically upgraded 
  For 2015 and later, one should copy CUDA 7.0.props, CUDA 7.0.targets, CUDA 7.0.xml and Nvda.Build.CudaTasks.v7.0.dll from C:\Program Files (x86)\MSBuild\Microsoft.Cpp\v4.0\V120(110)\BuildCustomizations to C:\Program Files (x86)\MSBuild\Microsoft.Cpp\v4.0\V140\BuildCustomizations before opening the Microsoft project files
- For CUDA Toolkit 8.0 and later:
  The Microsoft project files should be automatically upgraded on Visual Studio 2012 and later

