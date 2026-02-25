using System;
using Euresys.EGrabber;

namespace grabn
{
    class Program
    {
        static void sample(string[] args)
        {
            string outputDir = ".";
            if (args.Length > 0)
            {
                outputDir = args[0];
            }
            const UInt32 FRAME_COUNT = 20;
            using (EGenTL genTL = new EGenTL()) // use EGenTL(CtiPath.Gigelink) for Gigelink
            {                                   //  or EGenTL(CtiPath.Grablink) for the Grablink Duo
                using (EGrabberDiscovery discovery = new EGrabberDiscovery(genTL))
                {
                    discovery.Discover();
                    if (discovery.CameraCount == 0)
                    {
                        throw new Exception("No cameras discovered");
                    }
                    using (EGrabber grabber = new EGrabber(discovery.Cameras[0]))
                    {
                        grabber.ReallocBuffers(FRAME_COUNT);
                        var bufferSize = grabber.GetBufferInfo<ulong>(0, BUFFER_INFO_CMD.BUFFER_INFO_SIZE);
                        System.Console.WriteLine("Buffer size: {0}", bufferSize);

                        grabber.Start(FRAME_COUNT);
                        for (int frame = 0; frame < FRAME_COUNT; ++frame)
                        {
                            using (ScopedBuffer buffer = new ScopedBuffer(grabber))
                            {
                                ulong width = buffer.GetInfo<ulong>(BUFFER_INFO_CMD.BUFFER_INFO_WIDTH);
                                ulong height = buffer.GetInfo<ulong>(BUFFER_INFO_CMD.BUFFER_INFO_DELIVERED_IMAGEHEIGHT);
                                ulong dataSize = buffer.GetInfo<ulong>(BUFFER_INFO_CMD.BUFFER_INFO_DATA_SIZE);
                                ulong timestamp = buffer.GetInfo<ulong>(BUFFER_INFO_CMD.BUFFER_INFO_TIMESTAMP);

                                System.Console.WriteLine("Acquisition Index: {0}", frame);
                                System.Console.WriteLine(" - Width: {0}", width);
                                System.Console.WriteLine(" - Height: {0}", height);
                                System.Console.WriteLine(" - Data Size: {0}", dataSize);
                                System.Console.WriteLine(" - Timestamp: {0}.{1}", timestamp / 1000000, /*std::setw(6) << std::setfill('0')*/ timestamp % 1000000);

                                using (ConvertedBuffer conv = buffer.Convert("BGR8"))
                                {
                                    conv.SaveToDisk($"{outputDir}/frame.NNN.jpeg", frame);
                                }
                            }
                        }
                    }
                }
            }
        }

        static void Main(string[] args)
        {
            try
            {
                sample(args);
            }
            catch (System.Exception e)
            {
                System.Console.WriteLine(e.Message);
                Environment.Exit(1);
            }
        }
    }
}
