#include <EGrabber.h>
#include <iostream>

using namespace Euresys;

int main() {
    try {
        EGenTL genTL;
        EGrabberDiscovery disc(genTL);
        disc.discover(false);
        if (disc.egrabberCount() > 0) {
            EGrabber<CallbackOnDemand> grabber(disc.egrabbers(0));
            std::string did = grabber.getString<DeviceModule>("DeviceID");
            std::cout << "DeviceID: " << did << std::endl;
        }
    } catch (std::exception &e) {
        std::cerr << "Exception: " << e.what() << std::endl;
        return 1;
    }
    return 0;
}
