using Euresys.EGrabber;
using ManagedCuda;
using ManagedCuda.VectorTypes;
using ManagedCuda.NVRTC;
using ManagedCuda.BasicTypes;

namespace egrabbercuda
{
    class Program
    {
        static unsafe void Sample(string[] args)
        {
            string outputDir = ".";
            if (args.Length > 0)
            {
                outputDir = args[0];
            }
            Console.WriteLine("Initializing grabber");
            using EGenTL genTL = new EGenTL();
            using EGrabber grabber = new EGrabber(genTL);

            Console.WriteLine("Initializing CUDA");
            string kernelFileName = "invertKernel.cu";
            string kernelFileContents = File.ReadAllText(kernelFileName);
            byte[] ptx;
            using (CudaRuntimeCompiler rtc = new CudaRuntimeCompiler(kernelFileContents, "invertKernel"))
            {
                rtc.Compile(args);
                ptx = rtc.GetPTX();
            }

            using CudaContext ctx = new CudaContext(0);
            CudaKernel invertKernel = ctx.LoadKernelPTX(ptx, "invertKernel");

            Console.WriteLine("Announcing buffers");
            grabber.Remote.Set<string>("PixelFormat", "Mono8");
            ulong bufferSize = grabber.PayloadSize;

            using CudaPageLockedHostMemory<byte> pageLocked = new CudaPageLockedHostMemory<byte>(bufferSize, CUMemHostAllocFlags.DeviceMap);
            grabber.AnnounceAndQueue(new UserMemory(new UnmanagedMemoryStream((byte*)pageLocked.PinnedHostPointer, (long)bufferSize)));

            Console.WriteLine("Starting acquisition");
            grabber.Start(1);
            using (var buffer = new ScopedBuffer(grabber, 1000))
            {
                using var mono8 = buffer.Convert("Mono8");
                Console.WriteLine("Exporting input buffer");
                mono8.SaveToDisk($"{outputDir}/input_frame.bmp");
            }
            Console.WriteLine("Stopping acquisition");
            grabber.Stop();

            Console.WriteLine("Launching CUDA kernel");
            int threadsPerBlock = 1024;
            int blocksPerGrid = ((int)bufferSize + threadsPerBlock - 1) / threadsPerBlock;
            invertKernel.BlockDimensions = new dim3(threadsPerBlock, 1, 1);
            invertKernel.GridDimensions = new dim3(blocksPerGrid, 1, 1);
            invertKernel.Run(pageLocked.GetDevicePointer(), bufferSize);

            Console.WriteLine("Exporting output buffer");
            genTL.ImageSaveToDisk(new ImageConvertInput((int)grabber.Width, (int)grabber.Height, "Mono8", pageLocked.PinnedHostPointer, bufferSize, (int)grabber.Width), $"{outputDir}/output_frame.bmp");

            grabber.ReallocBuffers(0);
            Console.WriteLine("Finished");
        }

        static void Main(string[] args)
        {
            try
            {
                Sample(args);
            }
            catch (System.Exception e)
            {
                System.Console.WriteLine(e.Message);
                Environment.Exit(1);
            }
        }
    }
}
