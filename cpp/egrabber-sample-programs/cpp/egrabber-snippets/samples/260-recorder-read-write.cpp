#include "../tools/tools.h"

#include <EGrabber.h>
#include <recorder/EGrabberRecorder.h>

using namespace Euresys;
using namespace EGrabberRecorder;

static void processRecordedBuffer(RECORDER_BUFFER_INFO *info, void *data) {
    (void)info;
    (void)data;
    // processing code
}

static void sample() {
    EGenTL genTL; // load GenTL producer
    RecorderLibrary recorderLib; // load Recorder library
    // get an existing directory where the recorder container will be stored
    std::string containerPath = Tools::getEnv("sample-output-path");

    // the following block shows how to write a few buffers to a recorder
    // container opened in write mode
    {
        // create a new recorder container for writing
        Recorder recorder(recorderLib.openRecorder(containerPath, RECORDER_OPEN_MODE_WRITE));

        EGrabber<CallbackOnDemand> grabber(genTL); // create grabber

        // configure the grabber data stream to allocate and announce buffers
        // with optimal alignment for better recorder performance
        int64_t alignment = recorder.getParameterInteger(RECORDER_PARAMETER_BUFFER_OPTIMAL_ALIGNMENT);
        grabber.setString<StreamModule>("BufferAllocationAlignmentControl", "Enable");
        grabber.setInteger<StreamModule>("BufferAllocationAlignment", alignment);
        grabber.reallocBuffers(3); // allocate and announce aligned buffers

        size_t bufferSize = grabber.getBufferInfo<size_t>(0, gc::BUFFER_INFO_SIZE);
        const size_t N = 10;
        // allocate recorder container space for N buffers
        recorder.setParameterInteger(RECORDER_PARAMETER_CONTAINER_SIZE, N * bufferSize);

        grabber.start(N); // grab N buffers
        for (size_t frame = 0; frame < N; ++frame) {
            ScopedBuffer buffer(grabber); // wait and get a buffer
            // prepare recorder buffer info
            RECORDER_BUFFER_INFO info = {};
            info.size = buffer.getInfo<size_t>(gc::BUFFER_INFO_SIZE);
            info.pitch = buffer.getInfo<size_t>(ge::BUFFER_INFO_CUSTOM_LINE_PITCH);
            info.width = buffer.getInfo<size_t>(gc::BUFFER_INFO_WIDTH);
            info.height = buffer.getInfo<size_t>(gc::BUFFER_INFO_DELIVERED_IMAGEHEIGHT);
            info.pixelformat = static_cast<uint32_t>(buffer.getInfo<uint64_t>(gc::BUFFER_INFO_PIXELFORMAT));
            info.partCount = static_cast<uint32_t>(buffer.getInfo<size_t>(ge::BUFFER_INFO_CUSTOM_NUM_PARTS));
            info.partSize = buffer.getInfo<size_t>(ge::BUFFER_INFO_CUSTOM_PART_SIZE);
            info.timestamp = buffer.getInfo<uint64_t>(gc::BUFFER_INFO_TIMESTAMP_NS);
            info.userdata = frame;
            // get pointer to buffer data
            void *data = buffer.getInfo<void *>(gc::BUFFER_INFO_BASE);
            // write buffer info & data to the recorder container
            recorder.write(&info, data);
            Tools::log("Buffer #" + Tools::toString(frame) + " (" +
                Tools::toString(info.width) + "x" + Tools::toString(info.height) + " " +
                genTL.imageGetPixelFormat(info.pixelformat) + ", " +
                "userdata=" + Tools::toString(info.userdata) + ") " +
                "has been written to the container"
            );
        }
        // the recorder is automatically closed when going out of scope
    }

    // the following block shows how to read buffers from the existing recorder
    // container opened in read mode
    {
        // open the recorder container for reading
        Recorder recorder(recorderLib.openRecorder(containerPath, RECORDER_OPEN_MODE_READ));

        // query the number of available buffers in the recorder container
        int64_t count = recorder.getParameterInteger(RECORDER_PARAMETER_RECORD_COUNT);

        // the RECORDER_PARAMETER_RECORD_INDEX is set to 0 by default so the first
        // buffer of the container can be read immediately
        for (int64_t i = 0; i < count; ++i) {
            RECORDER_BUFFER_INFO info = {};
            // read buffer info & data from the recorder container
            std::vector<char> buffer(recorder.read(&info));
            // the RECORDER_PARAMETER_RECORD_INDEX is automatically incremented
            // so the next read will get the next buffer
            Tools::log("Buffer #" + Tools::toString(i) + " (" +
                Tools::toString(info.width) + "x" + Tools::toString(info.height) + " " +
                genTL.imageGetPixelFormat(info.pixelformat) + ", " +
                "userdata=" + Tools::toString(info.userdata) + ") " +
                "has been read from the container"
            );
            processRecordedBuffer(&info, &buffer[0]);
        }
    }
}

static Tools::Sample addSample(__FILE__, sample, "Write/Read buffers to/from a Recorder container");
