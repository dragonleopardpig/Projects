#include "../tools/tools.h"

#include <EGrabber.h>

using namespace Euresys;

static void showElements(const std::string &moduleName, const std::vector<std::string> &vect) {
    Tools::log(moduleName + " features: ");
    typedef std::vector<std::string>::const_iterator string_iterator;
    for (string_iterator it = vect.begin(); it != vect.end(); it++) {
        Tools::log("  " + *it);
    }
}

static void sample() {
    EGenTL genTL;
    EGrabberCallbackOnDemand grabber(genTL);
    showElements("RemoteModule", grabber.getStringList<RemoteModule>(query::features()));
}

static Tools::Sample addSample(__FILE__, sample, "Basic usage of EGrabber method getStringList");
