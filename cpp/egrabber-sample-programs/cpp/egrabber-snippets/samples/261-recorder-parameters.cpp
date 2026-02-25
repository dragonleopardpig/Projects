#include "../tools/tools.h"

#include <recorder/EGrabberRecorder.h>

using namespace Euresys;
using namespace EGrabberRecorder;

static void showRecorderParameters(Recorder &recorder) {
    Tools::log("Recorder parameters");
    Tools::log("-------------------");
    Tools::log(" - RECORDER_PARAMETER_VERSION: " + Tools::toString(recorder.getParameterString(RECORDER_PARAMETER_VERSION)));
    Tools::log(" - RECORDER_PARAMETER_CONTAINER_SIZE: " + Tools::toString(recorder.getParameterInteger(RECORDER_PARAMETER_CONTAINER_SIZE)));
    Tools::log(" - RECORDER_PARAMETER_RECORD_INDEX: " + Tools::toString(recorder.getParameterInteger(RECORDER_PARAMETER_RECORD_INDEX)));
    Tools::log(" - RECORDER_PARAMETER_RECORD_COUNT: " + Tools::toString(recorder.getParameterInteger(RECORDER_PARAMETER_RECORD_COUNT)));
    Tools::log(" - RECORDER_PARAMETER_REMAINING_SPACE_ON_DEVICE: " + Tools::toString(recorder.getParameterInteger(RECORDER_PARAMETER_REMAINING_SPACE_ON_DEVICE)));
    Tools::log(" - RECORDER_PARAMETER_BUFFER_OPTIMAL_ALIGNMENT: " + Tools::toString(recorder.getParameterInteger(RECORDER_PARAMETER_BUFFER_OPTIMAL_ALIGNMENT)));
    Tools::log(" - RECORDER_PARAMETER_DATABASE_VERSION: " + Tools::toString(recorder.getParameterInteger(RECORDER_PARAMETER_DATABASE_VERSION)));
    Tools::log(" - RECORDER_PARAMETER_REMAINING_SPACE_IN_CONTAINER: " + Tools::toString(recorder.getParameterInteger(RECORDER_PARAMETER_REMAINING_SPACE_IN_CONTAINER)));
}

static void sample() {
    RecorderLibrary recorderLib; // load Recorder library
    // get an existing directory where the recorder container will be stored
    std::string containerPath = Tools::getEnv("sample-output-path");

    {
        Tools::log("Create a recorder for writing with automatic trim on close");
        Recorder recorder(recorderLib.openRecorder(containerPath, RECORDER_OPEN_MODE_WRITE, RECORDER_CLOSE_MODE_TRIM));

        Tools::log("Allocate recorder container space for 1000000 bytes");
        recorder.setParameterInteger(RECORDER_PARAMETER_CONTAINER_SIZE, 1000000);
        // Note: the recorder size will be rounded up to meet the alignment constraint;
        // the recorder size will be a multiple of RECORDER_PARAMETER_BUFFER_OPTIMAL_ALIGNMENT

        Tools::log("Write a 1000-byte buffer to the container");
        // write a dummy buffer to show the impact on the recorder parameters
        RECORDER_BUFFER_INFO info = {};
        std::vector<char> data(1000);
        info.size = data.size();
        info.pitch = 100;
        info.width = 100;
        info.height = 10;
        info.pixelformat = 0x01080001; // PFNC Mono8
        info.partCount = 1;
        recorder.write(&info, &data[0]);

        // query recorder parameters
        showRecorderParameters(recorder);

        // Note: the recorder is automatically closed when going out of scope;
        // the RECORDER_CLOSE_MODE_TRIM will reduce the container size to the
        // smallest size that fits the container contents (i.e. the buffer we
        // have just written to the container)
        Tools::log("Trim & close the recorder container");
    }

    {
        Tools::log("Reopen the recorder for reading");
        Recorder recorder(recorderLib.openRecorder(containerPath, RECORDER_OPEN_MODE_READ));

        // query recorder parameters
        showRecorderParameters(recorder);

        Tools::log("Close the recorder container");
    }
}

static Tools::Sample addSample(__FILE__, sample, "Show Recorder parameters");
