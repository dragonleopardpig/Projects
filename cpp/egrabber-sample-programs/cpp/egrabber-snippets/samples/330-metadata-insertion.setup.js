var configure = require('egrabber://configurator.js');

var parameters = {
    OperatingMode:              "RG",
    // Camera Model
    ExposureReadoutOverlap:     true,
    ExposureRecoveryTime:       10,
    CycleMinimumPeriod:         30,
    // Cycle Timing
    ExposureTime:               20,
    StrobeDuration:             0,
    StrobeDelay:                0,
    // Cycle Control
    CycleTriggerSource:         "Immediate"
};

configure(grabbers[0], parameters);

var p = grabbers[0].StreamPort;
p.set('StartOfScanTriggerSource', 'Immediate');
p.set('EndOfScanTriggerSource', 'ScanLength');
p.set('ScanLength', 500);
p.set('BufferHeight', 500);

p.set("MetadataContent0", "GPC1Value");
p.set("MetadataContent3", "LineStatusAll");

p.set("GeneralPurposeCounterSelector", "GPC1");
p.set("GeneralPurposeCounterIncrementSource", "CycleStart");
p.set("GeneralPurposeCounterDecrementSource", "NONE");
p.set("GeneralPurposeCounterLatchAndResetSource", "NONE");
p.set("GeneralPurposeCounterEnable", true);

p.set("LineMetadataInsertionEnable", true);
p.set("BufferMetadataInsertionEnable", true);
