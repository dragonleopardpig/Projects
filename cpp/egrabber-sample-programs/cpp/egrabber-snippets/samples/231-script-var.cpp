#include "../tools/tools.h"
#include <EGrabber.h>

using namespace Euresys;

static void sample() {
    EGenTL genTL;
    EGrabber<CallbackOnDemand> grabber(genTL);
    // Declare and set virtual variables from c++
    grabber.setString<DeviceModule>(action::declareString(), "cppGreeting");
    grabber.setString<DeviceModule>("$cppGreeting", "Pleased to meet you");
    grabber.setString<RemoteModule>(action::declareString(), "cppGreeting");
    grabber.setString<RemoteModule>("$cppGreeting", "Nice to meet you");
    grabber.setString<StreamModule>(action::declareString(), "cppGreeting");
    grabber.setString<StreamModule>("$cppGreeting", "Glad to see you");
    // Run a script that uses the virtual variables created by c++
    grabber.runScript(Tools::getSampleFilePath("231-script-var.greetingsFromCpp.js"));
    // Run a script that declares and set virtual variables
    grabber.runScript(Tools::getSampleFilePath("231-script-var.numbersFromScript.js"));
    // Get the virtual variables created by the script
    Tools::log("From Cpp: <DeviceModule> $jsOne = " + Tools::toString(grabber.getInteger<DeviceModule>("$jsOne")));
    Tools::log("From Cpp: <RemoteModule> $jsTwo = " + Tools::toString(grabber.getFloat<RemoteModule>("$jsTwo")));
    Tools::log("From Cpp: <StreamModule> $jsThree = " + Tools::toString(grabber.getString<StreamModule>("$jsThree")));
}

static Tools::Sample addSample(__FILE__, sample, "Create and use virtual features from native code and Euresys scripts");
