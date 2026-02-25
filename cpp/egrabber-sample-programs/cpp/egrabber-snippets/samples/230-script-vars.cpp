#include "../tools/tools.h"

#include <EGrabber.h>

using namespace Euresys;

static void sample() {
    EGenTL genTL;
    EGrabber<CallbackOnDemand> grabber(genTL);

    // Create a string variable called 'message'
    // Variables are accessed using a '$' prefix
    grabber.setString<DeviceModule>(action::declareString(), "message");
    // Set the string variable '$message' like a feature
    grabber.setString<DeviceModule>("$message", "Hello World");
    // Use the string variable '$message' in a script
    grabber.runScript("console.log('[script] $message=' + grabbers[0].DevicePort.get('$message'));"
                      "grabbers[0].DevicePort.set('$message', 'Goodbye!');");
    // Get the string variable value from script to native code
    std::string message(grabber.getString<DeviceModule>("$message"));
    Tools::log("[native] $message=" + message);

    // Another example with integer and float variables
    grabber.setString<StreamModule>(action::declareInteger(), "a");
    grabber.setString<StreamModule>(action::declareFloat(), "b");
    grabber.setString<StreamModule>(action::declareFloat(), "result");
    grabber.setInteger<StreamModule>("$a", 2);
    grabber.setFloat<StreamModule>("$b", 12.11);
    // Compute "$result = $a * $b" in a script
    grabber.runScript("var a = grabbers[0].StreamPort.get('$a');"
                      "var b = grabbers[0].StreamPort.get('$b');"
                      "var result = a * b;"
                      "console.log('[script] result=' + result);"
                      "grabbers[0].StreamPort.set('$result', result);");
    // And get back the result
    double result = grabber.getFloat<StreamModule>("$result");
    Tools::log("[native] $result=" + Tools::toString(result));
}

static Tools::Sample addSample(__FILE__, sample, "Pass data between native code and Euresys script");
