#ifndef EGRABBER_CUDA_SAMPLE_HEADER_FILE
#define EGRABBER_CUDA_SAMPLE_HEADER_FILE

#include <string>
#include <map>
#include <vector>
#include <EGrabber.h>
#include "cuda.h"
#include "locks.h"

// Command line options
#define CUDA_HOSTMEMORY "cudaHostMemory"
#define CUDA_RDMA       "cudaRDMA"
#define PROFILING       "profiling"
#define DISABLEVSYNC    "disablevsync"
#define SHOWEXTENSIONS  "showExtensions"

typedef std::map<std::string, bool> Options;

class MyGrabber: public Euresys::EGrabberCallbackMultiThread {
public:
    MyGrabber(Euresys::EGenTL &gentl);
    ~MyGrabber();
private:
    virtual void onNewBufferEvent(const Euresys::NewBufferData &data);
};

extern Options options;
extern Euresys::Sample::ConcurrencyLock lock;
extern Euresys::Buffer *currentBuffer;
extern MyGrabber *grabber;

void initOpenGL(int *argc, char **argv);
GLuint setupGLObjects(size_t width, size_t height);
void setupCudaResources(size_t width, size_t height, GLuint tex);
void cleanupCudaResources(void);

void initCuda();
void cleanupCuda();
void allocateAndAnnounceBuffers(MyGrabber &grabber, std::vector<unsigned char *> &pinnedMemory /* items should be NULL */);
void releaseBuffers(std::vector<unsigned char *> &pinnedMemory);

bool updateTexture() throw();

#endif
