#include <iostream>
#include <EGrabber.h> 

static const uint32_t CARD_IX = 0;
static const uint32_t DEVICE_IX = 0;

void showInfo() {
    Euresys::EGenTL gentl;
    Euresys::EGrabber<> grabber(gentl, CARD_IX, DEVICE_IX);

    std::string card = grabber.getString<Euresys::InterfaceModule>("InterfaceID");
    std::string dev = grabber.getString<Euresys::DeviceModule>("DeviceID");
    int64_t width = grabber.getInteger<Euresys::RemoteModule>("Width");
    int64_t height = grabber.getInteger<Euresys::RemoteModule>("Height");

    std::cout << "Interface:    " << card << std::endl;
    std::cout << "Device:       " << dev  << std::endl;
    std::cout << "Resolution:   " << width << "x" << height << std::endl;
}

int main() {
  try {
        showInfo();
    } catch (const std::exception &e) {
        std::cout << "error: " << e.what() << std::endl;
    }
}
