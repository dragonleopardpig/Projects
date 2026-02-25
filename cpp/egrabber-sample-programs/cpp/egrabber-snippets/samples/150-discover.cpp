#include "../tools/tools.h"

#include <EGrabber.h>
#include <sstream>

using namespace Euresys;

static std::string eGrabberInfo(const EGrabberInfo &info)
{
    std::stringstream ss;
    ss << info.interfaceID + "/" + info.deviceID + "/" + info.streamID;
    if (info.isRemoteAvailable) {
        ss << "  (" + info.deviceModelName + ")";
    }
    return ss.str();
}

static void showEGrabberDetails(const EGrabberDiscovery &discovery, int ix)
{
    EGrabberInfo info = discovery.egrabbers(ix);
    Tools::log(" - egrabbers[" + Tools::toString(ix) + "]: " + eGrabberInfo(info));
}

static void showCameraDetails(const EGrabberDiscovery &discovery, int ix)
{
    EGrabberCameraInfo info = discovery.cameras(ix);
    Tools::log(" - cameras[" + Tools::toString(ix) + "]");
    if (info.grabbers.size() > 1) {
        Tools::log("    - This is a multi-bank camera composed by the following grabbers");
    }
    for (size_t i = 0; i < info.grabbers.size(); ++i) {
        Tools::log("    - grabbers[" + Tools::toString(i) + "]: " + eGrabberInfo(info.grabbers[i]));
    }
}

static void grabImages(EGrabber<CallbackOnDemand> &grabber, const std::string &outputFilePattern)
{
    static const size_t N = 10;
    grabber.reallocBuffers(3);
    grabber.start();
    Tools::log("Grabbing and saving " + Tools::toString(N) + " images into " + outputFilePattern);
    for (size_t frame = 0; frame < N; ++frame) {
        Tools::log(" - image #" + Tools::toString(frame));
        ScopedBuffer buffer(grabber); // wait and get a buffer
        buffer.saveToDisk(outputFilePattern, frame);
    }
    grabber.stop();
}

static void sample() {
    EGenTL genTL(Coaxlink()); // load CoaxLink GenTL producer
    EGrabberDiscovery discovery(genTL);

    Tools::log("Scanning the system for available eGrabbers and cameras");
    discovery.discover(false); // grabber-oriented discovery (camera discovery needs JS runtime)

    // Note: discovery.discover(false) will only scan for available eGrabbers
    // while discovery.discover(/* true */) will also scan for available cameras

    // Please note that the camera-oriented discovery (i.e. the default
    // behavior of discover()) takes more time to complete because it inspects
    // all the grabbers of the system to present a list of available cameras;
    // A multi-bank camera that exposes several CoaXPress devices (each device
    // providing a part of the acquired images) can be detected by the
    // camera-oriented discovery as a *single* camera; indeed the discovery is
    // able to identify which devices go together and how to reorder them so the
    // master device is always in the first position

    Tools::log("");
    Tools::log("Discovery result for eGrabbers");
    Tools::log("------------------------------");
    if (discovery.egrabberCount() == 0) {
        Tools::log("No eGrabber detected in the system");
    } else if (discovery.egrabberCount() == 1) {
        Tools::log("There is one eGrabber in the system");
    } else {
        Tools::log("There are " + Tools::toString(discovery.egrabberCount()) + " eGrabbers in the system");
    }
    for (int i = 0; i < discovery.egrabberCount(); ++i) {
        showEGrabberDetails(discovery, i);
    }
    if (discovery.egrabberCount()) {
        Tools::log("Creating a grabber instance for the first eGrabber");
        EGrabber<CallbackOnDemand> g(discovery.egrabbers(0));
        std::string outputFilePattern = Tools::getEnv("sample-output-path") + "/egrabbers[0].NNN.jpeg";
        grabImages(g, outputFilePattern);
    }

    Tools::log("");
    Tools::log("Discovery result for cameras");
    Tools::log("----------------------------");
    if (discovery.cameraCount() == 0) {
        Tools::log("No camera detected in the system");
    } else if (discovery.cameraCount() == 1) {
        Tools::log("There is one camera in the system");
    } else {
        Tools::log("There are " + Tools::toString(discovery.cameraCount()) + " cameras in the system");
    }
    for (int i = 0; i < discovery.cameraCount(); ++i) {
        showCameraDetails(discovery, i);
    }
    if (discovery.cameraCount()) {
        Tools::log("Creating a grabber instance for the first camera");
        EGrabber<CallbackOnDemand> g(discovery.cameras(0));

        // Note: this EGrabber construction also supports discovered multi-bank
        // cameras; in such a case, the EGrabber instance will behave as a
        // usual EGrabber to provide the user with an easy and simple control
        // over more complex devices. The NewBuffer events will be fired when
        // the composite buffer is filled by all the camera devices while the
        // other events will be directly fired from each composing grabbers (the
        // new method getLastEventGrabberIndex can be used to know about the
        // source of an event)

        std::string outputFilePattern = Tools::getEnv("sample-output-path") + "/cameras[0].NNN.jpeg";
        grabImages(g, outputFilePattern);
    }
}

static Tools::Sample addSample(__FILE__, sample, "Discover and create eGrabbers or cameras with EGrabberDiscovery\n"
    "(including discovery and usage of multi-bank cameras)");
