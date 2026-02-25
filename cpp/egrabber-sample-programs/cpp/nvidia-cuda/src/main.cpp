#include <iostream>
#include <iomanip>
#include <string>
#include <algorithm>

#include <GL/glew.h>
#include <GL/freeglut.h>
#include <GL/gl.h>

#include <cuda_runtime.h>
#include <cuda_gl_interop.h>
#include <cuda_profiler_api.h>

#include <EGrabber.h>
#include "egrabber-cuda.h"

using namespace Euresys;

#define NB_BUFFERS 3

Options options;
std::map<std::string, std::string> help;
Euresys::Sample::ConcurrencyLock lock;
Buffer *currentBuffer = NULL;
MyGrabber *grabber = NULL;

MyGrabber::MyGrabber(EGenTL &gentl) : EGrabberCallbackMultiThread(gentl) {};

MyGrabber::~MyGrabber() { shutdown(); }

void MyGrabber::onNewBufferEvent(const NewBufferData &data) {
    Euresys::Sample::AutoLock autoLock(lock);
    if (currentBuffer) {
        ScopedBuffer b(*this, data);
    } else {
        currentBuffer = new Buffer(data);
    }
}

void usage() {
    std::cout << "egrabber-cuda [OPTION]..." << std::endl;
    std::cout << std::endl;
    std::cout << "Available options: " << std::endl;
    for (Options::const_iterator i = options.begin(); i != options.end(); ++i) {
        std::cout << i->first << ":\t" << help[i->first] << std::endl;
    }
    std::cout << std::endl;
}

void showOptions(Options &options) {
    for (Options::const_iterator i = options.begin(); i != options.end(); ++i) {
        std::cout << i->first << ":\t" << ((i->second) ? "yes" : "no") << std::endl;
    }
}

void parseOptions(int argc, char **argv, Options &options) {
    for (int i = 1; i < argc; ++i) {
        std::string arg(argv[i]);
        Options::iterator it = options.find(arg);
        if (it != options.end()) {
            options[arg] = true;
        } else if (arg == "--") {
            // options for glutInit follow
            break;
        } else {
            usage();
            std::stringstream msg;
            msg << "unknown option '" << arg << "'";
            throw std::runtime_error(msg.str());
        }
    }
#ifndef __linux__
    if (options[CUDA_RDMA]) {
        std::cout << "Warning: CUDA kernels with RDMA are only supported in Linux. This parameter will be disabled." << std::endl;
        options[CUDA_RDMA] = false;
    }
#endif
}

void initOptions(Options &options) {
    options[CUDA_HOSTMEMORY] = false;
    help[CUDA_HOSTMEMORY] = "CUDA kernels use host memory (less efficient than GPU memory)";
    options[CUDA_RDMA] = false;
    help[CUDA_RDMA] = "CUDA kernels use CUDA memory with RDMA (Linux only)";
    options[PROFILING] = false;
    help[PROFILING] = "enable profiling of CUDA operations (to be used with nvprof)";
    options[DISABLEVSYNC] = false;
    help[DISABLEVSYNC] = "disable VSYNC for maximum frame rate";
    options[SHOWEXTENSIONS] = false;
    help[SHOWEXTENSIONS] = "show available OpenGL extensions";
}

void showGrabberInfo(MyGrabber &grabber) {
    std::cout << "resolution:\t" << grabber.getWidth() << "x" << grabber.getHeight() << std::endl;
    std::cout << "pixel format:\t" << grabber.getPixelFormat() << std::endl;
}

void checkFormat(MyGrabber &grabber) {
    if (grabber.getPixelFormat() != "Mono8") {
        throw std::runtime_error("This sample only works for Mono8 PixelFormat");
    }
}

int main(int argc, char **argv) {
    int exitCode = 0;
    std::vector<unsigned char *>pinnedMemory(NB_BUFFERS);
    initOptions(options);

    try {
        Euresys::EGenTL genTL;
        MyGrabber egrabber(genTL);
        grabber = &egrabber;

        parseOptions(argc, argv, options);
        showOptions(options);

        egrabber.runScript("./config.js");
        showGrabberInfo(egrabber);
        checkFormat(egrabber);

        initOpenGL(&argc, argv);
        initCuda();

        allocateAndAnnounceBuffers(egrabber, pinnedMemory);
        egrabber.start();

        GLuint tex = setupGLObjects(egrabber.getWidth(), egrabber.getHeight());
        setupCudaResources(egrabber.getWidth(), egrabber.getHeight(), tex);

        glutMainLoop();
    }
    catch (const std::exception &e) {
        std::cerr << e.what() << std::endl;
        exitCode = 1;
    }
    catch (...) {
        std::cerr << "uncaught exception!" << std::endl;
        exitCode = 1;
    }

    releaseBuffers(pinnedMemory);
    delete currentBuffer;
    cleanupCuda();

    return exitCode;
}
