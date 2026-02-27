// egrab-capture: helper binary for Euresys CoaxLink camera capture
// Usage:
//   egrab-capture --mode single --output /tmp/capture.raw
//     Grabs one frame, converts to Mono8, writes binary: [u32 width][u32 height][u32 len][gray data]
//
//   egrab-capture --mode stream
//     Continuously grabs frames, writes [u32 width][u32 height][u32 len][gray data] per frame to stdout
//     Reads stdin for 'q' to quit. Also handles SIGTERM/SIGPIPE.

#include <EGrabber.h>
#include <FormatConverter.h>
#include <iostream>
#include <fstream>
#include <cstring>
#include <cstdint>
#include <csignal>
#include <string>
#include <thread>
#include <atomic>
#include <fcntl.h>
#include <unistd.h>

using namespace Euresys;

static std::atomic<bool> g_running{true};

static void signal_handler(int) {
    g_running = false;
}

static void write_u32(std::ostream &out, uint32_t val) {
    out.write(reinterpret_cast<const char *>(&val), 4);
}

static void write_u32(FILE *fp, uint32_t val) {
    fwrite(&val, 4, 1, fp);
}

static int do_single(const std::string &output_path) {
    try {
        EGenTL genTL;
        EGrabberDiscovery disc(genTL);
        disc.discover();

        if (disc.egrabberCount() == 0) {
            std::cerr << "ERROR: No grabber found" << std::endl;
            return 1;
        }

        EGrabber<CallbackOnDemand> grabber(disc.egrabbers(0));
        FormatConverter converter(genTL);

        std::string deviceId = grabber.getString<DeviceModule>("DeviceID");
        std::cerr << "Device: " << deviceId << std::endl;

        int64_t width = grabber.getInteger<RemoteModule>("Width");
        int64_t height = grabber.getInteger<RemoteModule>("Height");
        std::cerr << "Resolution: " << width << "x" << height << std::endl;

        grabber.reallocBuffers(1);
        grabber.start(1);

        ScopedBuffer buffer(grabber);
        uint8_t *imagePointer = buffer.getInfo<uint8_t *>(gc::BUFFER_INFO_BASE);
        size_t bufWidth = buffer.getInfo<size_t>(gc::BUFFER_INFO_WIDTH);
        size_t bufHeight = buffer.getInfo<size_t>(gc::BUFFER_INFO_DELIVERED_IMAGEHEIGHT);
        uint64_t pixelFormat = buffer.getInfo<uint64_t>(gc::BUFFER_INFO_PIXELFORMAT);

        // Convert to Mono8 (grayscale — 1 byte per pixel)
        FormatConverter::Auto mono(converter, FormatConverter::OutputFormat("Mono8"),
            imagePointer, pixelFormat, bufWidth, bufHeight);

        size_t monoSize = bufWidth * bufHeight * 1;
        const uint8_t *monoData = reinterpret_cast<const uint8_t *>(mono.getBuffer());

        // Write binary: [width u32][height u32][len u32][gray data]
        std::ofstream out(output_path, std::ios::binary);
        if (!out) {
            std::cerr << "ERROR: Cannot open output file: " << output_path << std::endl;
            return 1;
        }

        uint32_t w32 = static_cast<uint32_t>(bufWidth);
        uint32_t h32 = static_cast<uint32_t>(bufHeight);
        uint32_t len32 = static_cast<uint32_t>(monoSize);
        write_u32(out, w32);
        write_u32(out, h32);
        write_u32(out, len32);
        out.write(reinterpret_cast<const char *>(monoData), monoSize);
        out.close();

        std::cerr << "Captured " << bufWidth << "x" << bufHeight << " -> " << output_path << std::endl;
        return 0;

    } catch (std::exception &e) {
        std::cerr << "ERROR: " << e.what() << std::endl;
        return 1;
    }
}

static int do_stream() {
    signal(SIGTERM, signal_handler);
    signal(SIGPIPE, signal_handler);

    // Make stdin non-blocking so we can poll for 'q'
    int flags = fcntl(STDIN_FILENO, F_GETFL, 0);
    fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK);

    try {
        std::cerr << "Initializing GenTL..." << std::endl;
        EGenTL genTL;
        std::cerr << "Discovering cameras..." << std::endl;
        EGrabberDiscovery disc(genTL);
        disc.discover();

        if (disc.egrabberCount() == 0) {
            std::cerr << "ERROR: No grabber found" << std::endl;
            return 1;
        }

        std::cerr << "Connecting to grabber..." << std::endl;
        EGrabber<CallbackOnDemand> grabber(disc.egrabbers(0));
        FormatConverter converter(genTL);

        std::string deviceId = grabber.getString<DeviceModule>("DeviceID");
        std::cerr << "Device: " << deviceId << std::endl;

        int64_t width = grabber.getInteger<RemoteModule>("Width");
        int64_t height = grabber.getInteger<RemoteModule>("Height");
        std::cerr << "Resolution: " << width << "x" << height << std::endl;

        grabber.reallocBuffers(8);
        grabber.start();  // continuous
        std::cerr << "Streaming" << std::endl;

        FILE *out = stdout;
        uint64_t frame_count = 0;

        while (g_running) {
            // Check stdin for quit command
            char ch;
            if (read(STDIN_FILENO, &ch, 1) == 1 && (ch == 'q' || ch == 'Q')) {
                std::cerr << "Quit requested" << std::endl;
                break;
            }

            try {
                ScopedBuffer buffer(grabber, 1000); // 1s timeout
                uint8_t *imagePointer = buffer.getInfo<uint8_t *>(gc::BUFFER_INFO_BASE);
                size_t bufWidth = buffer.getInfo<size_t>(gc::BUFFER_INFO_WIDTH);
                size_t bufHeight = buffer.getInfo<size_t>(gc::BUFFER_INFO_DELIVERED_IMAGEHEIGHT);
                uint64_t pixelFormat = buffer.getInfo<uint64_t>(gc::BUFFER_INFO_PIXELFORMAT);

                FormatConverter::Auto mono(converter, FormatConverter::OutputFormat("Mono8"),
                    imagePointer, pixelFormat, bufWidth, bufHeight);

                size_t monoSize = bufWidth * bufHeight * 1;
                const uint8_t *monoData = reinterpret_cast<const uint8_t *>(mono.getBuffer());

                uint32_t w32 = static_cast<uint32_t>(bufWidth);
                uint32_t h32 = static_cast<uint32_t>(bufHeight);
                uint32_t len32 = static_cast<uint32_t>(monoSize);

                write_u32(out, w32);
                write_u32(out, h32);
                write_u32(out, len32);
                if (fwrite(monoData, 1, monoSize, out) != monoSize) {
                    std::cerr << "Write error (pipe closed?)" << std::endl;
                    break;
                }
                fflush(out);

                frame_count++;
                if (frame_count % 10 == 0) {
                    std::cerr << "Frames: " << frame_count << std::endl;
                }

            } catch (std::exception &e) {
                std::string msg = e.what();
                if (msg.find("timeout") != std::string::npos ||
                    msg.find("Timeout") != std::string::npos) {
                    continue; // timeout is ok, just retry
                }
                std::cerr << "Frame error: " << msg << std::endl;
                break;
            }
        }

        grabber.stop();
        std::cerr << "Stopped after " << frame_count << " frames" << std::endl;
        return 0;

    } catch (std::exception &e) {
        std::cerr << "ERROR: " << e.what() << std::endl;
        return 1;
    }
}

int main(int argc, char *argv[]) {
    std::string mode = "single";
    std::string output = "/tmp/egrab-capture.raw";

    for (int i = 1; i < argc; i++) {
        if (std::string(argv[i]) == "--mode" && i + 1 < argc) {
            mode = argv[++i];
        } else if (std::string(argv[i]) == "--output" && i + 1 < argc) {
            output = argv[++i];
        } else if (std::string(argv[i]) == "--help") {
            std::cerr << "Usage: egrab-capture [--mode single|stream] [--output file.raw]" << std::endl;
            return 0;
        }
    }

    if (mode == "single") {
        return do_single(output);
    } else if (mode == "stream") {
        return do_stream();
    } else {
        std::cerr << "Unknown mode: " << mode << std::endl;
        return 1;
    }
}
