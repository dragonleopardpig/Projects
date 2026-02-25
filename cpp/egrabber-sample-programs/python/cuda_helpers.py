from cuda.bindings import driver as driver
from cuda.bindings import nvrtc as nvrtc
from enum import EnumMeta

class CudaError(Exception):
    def __init__(self, code):
        self.code = code
    def __str__(self):
        err, msg = driver.cuGetErrorString(self.code)
        err, name = driver.cuGetErrorName(self.code)
        return '{} ({}): {}'.format(name.decode('utf-8'), self.code, msg.decode('utf-8'))

def cuda_check(func):
    def wrapper(*args, **kwargs):
        result, *values = func(*args, **kwargs)
        if result != 0:
            raise CudaError(result)
        if len(values) == 0:
            return
        if len(values) == 1:
            return values[0]
        else:
            return tuple(values)
    return wrapper

class Cuda:
    def __init__(self, cuda_module):
        self.cuda_module = cuda_module
    def __getattr__(self, name, wrap_cuda_check=True):
        attr = getattr(self.cuda_module, name)
        if wrap_cuda_check and callable(attr) and not issubclass(type(attr), EnumMeta):
            attr = cuda_check(attr)
        return attr

def cuda_build_kernel(cuda_driver, device_number, kernel_code):
    cuda_device = cuda_driver.cuDeviceGet(device_number)
    major = cuda_driver.cuDeviceGetAttribute(cuda_driver.CUdevice_attribute.CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MAJOR, cuda_device)
    minor = cuda_driver.cuDeviceGetAttribute(cuda_driver.CUdevice_attribute.CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MINOR, cuda_device)
    arch_arg = bytes(f'--gpu-architecture=compute_{major}{minor}', 'ascii')

    cuda_compiler = Cuda(nvrtc)
    prog = cuda_compiler.nvrtcCreateProgram(kernel_code.encode(), b"kernelCode.cu", 0, [], [])
    cuda_compiler.nvrtcCompileProgram(prog, 1, [arch_arg])

    ptx_size = cuda_compiler.nvrtcGetPTXSize(prog)
    ptx = bytearray(ptx_size)
    cuda_compiler.nvrtcGetPTX(prog, ptx)
    cuda_compiler.nvrtcDestroyProgram(prog)

    cuda_module = cuda_driver.cuModuleLoadData(ptx)
    return cuda_module

def cuda_launch_kernel(cuda_driver, cuda_module, kernel_function_name, bdim, gdim, kernel_params):
    kernel_fn = cuda_driver.cuModuleGetFunction(cuda_module, kernel_function_name.encode())
    cuda_driver.cuLaunchKernel(kernel_fn,
                               gdim, 1, 1,
                               bdim, 1, 1,
                               0,
                               0,
                               kernel_params,
                               0,
                               )
