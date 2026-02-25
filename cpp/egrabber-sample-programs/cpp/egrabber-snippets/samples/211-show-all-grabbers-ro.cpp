#include "../tools/tools.h"

#include <EGrabber.h>

using namespace Euresys;

namespace {
    class AllGrabbers {
        public:
            AllGrabbers(EGenTL &genTL)
            {
                for (int interfaceIndex = 0; interfaceIndex < 4; ++interfaceIndex) {
                    for (int deviceIndex = 0; deviceIndex < 8; ++deviceIndex) {
                        try {
                            size_t index = grabbers.size();
                            grabbers.push_back(new Grabber(genTL, interfaceIndex, deviceIndex, 0, gc::DEVICE_ACCESS_READONLY));
                            Tools::log("Added Grabber[" + Tools::toString<size_t>(index) + "]"
                                " on interface " + Tools::toString<int>(interfaceIndex) +
                                " for device " + Tools::toString<int>(deviceIndex));
                        }
                        catch (const gentl_error &ge) {
                            switch (ge.gc_err) {
                                case gc::GC_ERR_INVALID_ADDRESS:
                                    Tools::log("Camera is not available"
                                        " on interface " + Tools::toString<int>(interfaceIndex) +
                                        " device " + Tools::toString<int>(deviceIndex));
                                    break;
                                case gc::GC_ERR_INVALID_INDEX:
                                    break;
                                default:
                                    throw;
                            }
                        }
                    }
                }
            }
            ~AllGrabbers() {
                for (size_t i = 0; i < grabbers.size(); ++i) {
                    try {
                        delete grabbers[i];
                        Tools::log("Closed Grabber[" + Tools::toString<size_t>(i) + "]");
                    }
                    catch (...) {
                    }
                }
            }
            void runScript(const std::string &scriptPath) {
                for (size_t i = 0; i < grabbers.size(); ++i) {
                    Tools::log("Run " + scriptPath + " on Grabber[" + Tools::toString<size_t>(i) + "]");
                    grabbers[i]->runScript(scriptPath);
                }
            }
        private:
            typedef EGrabber<CallbackOnDemand> Grabber;
            std::vector<Grabber *> grabbers;
    };
};

static void sample() {
    EGenTL genTL; // load GenTL producer
    AllGrabbers grabbers(genTL);
    grabbers.runScript(Tools::getSampleFilePath("211-show-all-grabbers-ro.show.js"));
}

static Tools::DeprecatedSample addSample(__FILE__, sample, "Show available grabbers (devices are opened with DEVICE_ACCESS_READONLY)\n"
    "Please use EGrabberDiscovery to list the available grabbers (cf. 150-discover)");
