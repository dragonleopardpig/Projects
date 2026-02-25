var configure = require('egrabber://configurator.js');

function fpsToMicroseconds(fps) {
    return 1e6 / fps;
}

var parameters = {
    OperatingMode:              "RG",
    // Camera Model
    ExposureReadoutOverlap:     true,
    ExposureRecoveryTime:       1000,
    CycleMinimumPeriod:         fpsToMicroseconds(20),
    // Cycle Timing
    ExposureTime:               5500,
    StrobeDuration:             1000,
    StrobeDelay:                100,
    // Cycle Control
    CycleTriggerSource:         "Immediate"
};

configure(grabbers[0], parameters);
