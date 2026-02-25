#include <EGrabber.h>
#include <iostream>

using namespace Euresys;

int main() {
    try {
        std::cout << "Loading GenTL..." << std::endl;
        EGenTL genTL;
        std::cout << "GenTL loaded OK" << std::endl;

        EGrabberDiscovery disc(genTL);
        disc.discover(false);
        std::cout << "egrabberCount: " << disc.egrabberCount() << std::endl;

        if (disc.egrabberCount() > 0) {
            EGrabberInfo info = disc.egrabbers(0);
            std::cout << "interfaceID: " << info.interfaceID << std::endl;
            std::cout << "deviceID: " << info.deviceID << std::endl;
            std::cout << "streamID: " << info.streamID << std::endl;
            std::cout << "isRemoteAvailable: " << info.isRemoteAvailable << std::endl;

            std::cout << "Creating EGrabber..." << std::endl;
            EGrabber<CallbackOnDemand> grabber(info);
            std::cout << "EGrabber created OK" << std::endl;

            try {
                std::string did = grabber.getString<DeviceModule>("DeviceID");
                std::cout << "DeviceID: " << did << std::endl;
            } catch (std::exception &e) {
                std::cout << "DeviceModule getString failed: " << e.what() << std::endl;
            }

            try {
                int n = grabber.getInteger<InterfaceModule>("InterfaceID");
                std::cout << "InterfaceID (int): " << n << std::endl;
            } catch (...) {}

            try {
                std::string iid = grabber.getString<InterfaceModule>("InterfaceID");
                std::cout << "InterfaceID: " << iid << std::endl;
            } catch (std::exception &e) {
                std::cout << "InterfaceModule getString failed: " << e.what() << std::endl;
            }

            try {
                std::string sid = grabber.getString<SystemModule>("TLVendorName");
                std::cout << "TLVendorName: " << sid << std::endl;
            } catch (std::exception &e) {
                std::cout << "SystemModule getString failed: " << e.what() << std::endl;
            }
        }
    } catch (std::exception &e) {
        std::cerr << "Exception: " << e.what() << std::endl;
        return 1;
    }
    return 0;
}
