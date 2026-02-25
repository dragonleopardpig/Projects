#include "../tools/tools.h"

#include <EGrabber.h>

using namespace Euresys;

static void sample() {
    typedef std::vector<std::string>::const_iterator it_t;

    EGenTL genTL; // load GenTL producer
    EGrabberCallbackOnDemand grabber(genTL); // create a grabber (first device on first interface)

    // get all the available GenApi features of the camera (RemoteModule)
    std::vector<std::string> cameraFeatures(grabber.getStringList<RemoteModule>(query::features()));

    // for each GenApi feature...
    for (it_t it = cameraFeatures.begin(); it != cameraFeatures.end(); it++) {
        const std::string &feature(*it);
        // check if it is a GenApi command
        bool isCommand = grabber.getInteger<RemoteModule>(query::command(feature)) != 0;
        if (isCommand) {
            // check if the GenApi command is "done" i.e. if it has completed its execution
            bool isCommandDone = grabber.getInteger<RemoteModule>(query::done(feature)) != 0;
            if (isCommandDone) {
                Tools::log("The command " + feature + " is done.");
            } else {
                Tools::log("The command " + feature + " is not done, it is still executing.");
            }
        }
    }
}

static Tools::Sample addSample(__FILE__, sample, "Queries on GenApi commands");
