#include "../tools/tools.h"

#include <EGrabber.h>

using namespace Euresys;

enum {
    MementoWaveDiscovery = 0,
    MementoWaveAcquisition = 1,
    MementoWaveFrame = 2,
};

/*
 * - Open memento
 * - Ensure "Enable analyzer" option is checked in the hamburger menu
 * - Run the sample
 * - In memento, Right-click on any trace and select "Show analyzer", this will open the "Analyzer Configurator" window
 * - In the "Analyzer Configurator", select "User0" in the Kinds
 * - Optionally give custom names to the user memento waves:
 *   - Click on Advanced tab in the "Analyzer Configurator"
 *   - Click on the "User0>UserWave0" in the bottom list and write "Discovery" in Alias property in the top part of the tab
 *   - Click on the "User0>UserWave1" in the bottom list and write "Acquisition" in Alias property in the top part of the tab
 *   - Click on the "User0>UserWaveValue2" in the bottom list and write "Frame" in Alias property in the top part of the tab
 * - Optionally change the colors of the memento waves:
 *   - Either automatically:
 *     - Go to Edit menu and select "Reassign automatic colors"
 *   - Or manually:
 *     - Click on Advanced tab in the "Analyzer Configurator"
 *     - Click on the elements of the bottom list and change the Color property in the top part of the tab
 * - Go back to the main memento window, Right-click on any trace and select "Analyze >" and "All"
 */

static void sample() {
    const unsigned char kind(0); // custom value between 0 and 15
    EGenTL genTL(Coaxlink()); // load CoaxLink GenTL producer

    // reset all waves to ensure a clean and known initial state
    genTL.mementoWaveReset(kind, MementoWaveDiscovery);
    genTL.mementoWaveReset(kind, MementoWaveAcquisition);
    genTL.mementoWaveNoValue(kind, MementoWaveFrame);

    EGrabberDiscovery egrabberDiscovery(genTL);
    genTL.mementoWaveUp(kind, MementoWaveDiscovery);
    egrabberDiscovery.discover(false);
    genTL.mementoWaveDown(kind, MementoWaveDiscovery);

    EGrabber<CallbackOnDemand> grabber(egrabberDiscovery.egrabbers(0));
    grabber.reallocBuffers(20); // prepare 20 buffers

    grabber.mementoWaveUp(kind, MementoWaveAcquisition);
    grabber.start(20); // grab 20 buffers
    for (size_t frame = 0; frame < 20; ++frame) {
        ScopedBuffer buffer(grabber); // wait and get a buffer
        grabber.mementoWaveValue(kind, MementoWaveFrame, frame);
    }
    grabber.mementoWaveDown(kind, MementoWaveAcquisition);

    // reset all waves to clearly indicate the end of any activity on these waves
    genTL.mementoWaveReset(kind, MementoWaveDiscovery);
    genTL.mementoWaveReset(kind, MementoWaveAcquisition);
    genTL.mementoWaveNoValue(kind, MementoWaveFrame);
}

static Tools::Sample addSample(__FILE__, sample, "Generate memento waves\n");
