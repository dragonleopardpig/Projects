#include "../tools/tools.h"
#include <EGrabber.h>
using namespace Euresys;

static void sample() {
    EGenTL genTL(Coaxlink());
    EGrabberDiscovery discovery(genTL);

    discovery.discover(false);
    int itf = -1;
    for (int i = 0; i < discovery.interfaceCount(); i++) {
        if (discovery.deviceCount(i) > 0) {
            itf = i;
            break;
        }
    }
    if (itf < 0) {
        throw std::runtime_error("No CoaxLink device found");
    }
    EGrabberInfo info = discovery.deviceInfo(itf, 0);
    EGrabber<CallbackOnDemand> setup(info, gc::DEVICE_ACCESS_CONTROL);
    setup.runScript(Tools::getSampleFilePath("270-multicast-master.setup.js"));
    setup.memento("Now ready to open multicast streams");

    EGrabber<CallbackOnDemand> grabber(discovery.streamInfo(itf, 0, 0), gc::DEVICE_ACCESS_CONTROL);

    std::cout << "Please start sample 271-multicast-receiver in another console, \n"
              << "       wait for message that claim it is ready to grab, \n"
              << "       then press ENTER to start acquisition.";
    std::cin.get();
    grabber.runScript(Tools::getSampleFilePath("270-multicast-master.setup.js"));
    grabber.execute<RemoteModule>("AcquisitionStart");

    std::cout << "Acquisition started. Receiver should soon be done.\n"
              << "Press ENTER to stop the acquisition...\n";
    std::cin.get();
}

static Tools::Sample addSample(__FILE__, sample, "Sending packets on multicast group\n"
    "(call sample 270-multicast-master before 271-multicast-receiver)");
