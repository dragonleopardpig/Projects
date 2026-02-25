#ifndef CHECK_SAMPLE_HEADER_FILE
#define CHECK_SAMPLE_HEADER_FILE

#include <iostream>
#include <sstream>
#include <string>

#define check(e) do { checkAndThrow((e), #e, __FILE__, __LINE__); } while (0)

namespace {

void checkAndThrow(const cudaError_t e, const char *call, const char *filename, int line) {
    if (e != cudaSuccess) {
        std::ostringstream message;
        message << call << " failed: " << cudaGetErrorString(e) << ", " << filename << ": " << line;
        throw std::runtime_error(message.str());
    }
}

}

#endif
