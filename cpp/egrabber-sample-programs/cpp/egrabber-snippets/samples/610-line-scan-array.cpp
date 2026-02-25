#include "../tools/tools.h"

#include <EGrabber.h>

using namespace Euresys;

namespace {

template <typename Grabber>
class BufferArray {
    public:
        BufferArray(Grabber &grabber)
        : grabber(grabber)
        , memory(UserMemory(0, 0), 0)
        , range(0, 0)
        {}
        virtual ~BufferArray() {
            try {
                freeArray();
            }
            catch (...) {
            }
        }
        void alloc(size_t bufferCount, size_t bufferSize = 0) {
            freeArray();
            if (bufferCount == 0) {
                return;
            }
            if (bufferSize == 0)  {
                bufferSize = grabber.getPayloadSize();
            }
            void *base = malloc(bufferCount * bufferSize);
            if (!base) {
                throw std::bad_alloc();
            }
            memory = UserMemoryArray(UserMemory(base, bufferCount * bufferSize), bufferSize);
            range = grabber.announceAndQueue(memory);
        }
        size_t bufferCount() const {
            return range.end - range.begin;
        }
        size_t bufferSize() const {
            return memory.bufferSize;
        }
        size_t arraySize() const {
            return memory.memory.size;
        }
        void *data(size_t bufferIndex = 0) const {
            if (bufferIndex >= bufferCount()) {
                throw std::out_of_range("buffer array");
            }
            char *base = reinterpret_cast<char *>(memory.memory.base);
            return &base[bufferIndex * memory.bufferSize];
        }
        template <typename T> T getBufferInfo(size_t bufferIndex, gc::BUFFER_INFO_CMD cmd) {
            return grabber.template getBufferInfo<T>(range.indexAt(bufferIndex), cmd);
        }
    private:
        void freeArray() {
            grabber.revoke(range);
            range = BufferIndexRange(0, 0);
            free(memory.memory.base);
            memory = UserMemoryArray(UserMemory(0, 0), 0);
        }
        Grabber &grabber;
        UserMemoryArray memory;
        BufferIndexRange range;
};

#ifdef _MSC_VER
#pragma warning( push )
#pragma warning( disable : 4355 ) // 'this' : used in base member initializer list
#endif
// Configure EGrabber in callback single-thread mode (ordered events)
class MyGrabber: public EGrabberCallbackSingleThread {
    public:
        MyGrabber(EGenTL &gentl)
        : EGrabberCallbackSingleThread(gentl)
        , bArray(*this)
        , done(false)
        {
            runScript(Tools::getSampleFilePath("610-line-scan-array.setup.js"));
            size_t scanLength = static_cast<size_t>(getInteger<StreamModule>("ScanLength"));
            size_t bufferHeight = getHeight();
            bArray.alloc((scanLength + bufferHeight - 1) / bufferHeight);
        }
        ~MyGrabber() {
            try {
                stop();
            }
            catch (...) {
            }
            try {
                runScript(Tools::getSampleFilePath("610-line-scan-array.teardown.js"));
            }
            catch (...) {
            }
            shutdown();
        }
        void saveScan(unsigned int i) {
            std::string format(getPixelFormat());
            ge::ImageConvertInput input = {0};
            input.width = static_cast<int>(getWidth());
            input.height = static_cast<int>(getInteger<StreamModule>("ScanLength"));
            if (input.height > 10000) {
                input.height = 10000;
                Tools::log("Limit height of scan to " + Tools::toString(input.height) + " while saving");
            }
            input.pixels = bArray.data();
            input.format = format.c_str();
            std::string path =
                Tools::getEnv("sample-output-path") +
                "/scan" +
                Tools::toString(input.width) + "x" +
                Tools::toString(input.height) + "_" +
                input.format +
                ".NNN.tiff";
            Tools::log("Saving scan to " + path + "...");
            getGenTL().imageSaveToDisk(input, path, i);
        }
        void startScan() {
            Tools::log("Start Scan: array of " + Tools::toString(bArray.bufferCount()) + " buffers");
            resetBufferQueue();
            start(bArray.bufferCount());
            execute<StreamModule>("StartScan");
        }
        void go() {
            disableEvent<All>(); // We don't need the new buffer events (they are enabled by the EGrabber constructor)
            enableEvent<DataStreamData>(); // We need the "end of scan" event from the data stream
            for (size_t i = 0; i < bArray.bufferCount(); ++i) {
                // Show array buffer address reported by BUFFER_INFO_BASE command
                void *base = bArray.getBufferInfo<void *>(i, gc::BUFFER_INFO_BASE);
                Tools::log("array[" + Tools::toString(i) + "] = " + Tools::toHexString(base));
                // Note: base == bArray.data(i);
            }
            startScan();
            while (!done) {
                Tools::sleepMs(100);
            }
        }
    private:
        BufferArray<MyGrabber> bArray;
        volatile bool done;

        virtual void onDataStreamEvent(const DataStreamData &data) {
            if (data.numid == ge::EVENT_DATA_NUMID_DATASTREAM_END_OF_SCAN) {
                uint32_t count = data.context1;
                Tools::log("Array of buffers is ready: EndOfScanEventCount=" + Tools::toString(count));
                saveScan(count);
                if (count < 3) {
                    startScan();
                } else {
                    done = true;
                }
            }
        }
};
#ifdef _MSC_VER
#pragma warning( pop )
#endif

}

static void sample() {
    EGenTL genTL;
    MyGrabber grabber(genTL);
    grabber.go();
}

static Tools::Sample addSample(__FILE__, sample, "Array of (contiguous) buffers on Line-Scan with EGrabber Single-Thread");
