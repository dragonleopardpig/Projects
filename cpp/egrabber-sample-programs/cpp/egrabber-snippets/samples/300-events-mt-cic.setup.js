require('./config-rg.js');

function configure(grabber) {
    var devPort = grabber.DevicePort;
    devPort.set("EventNotification[CameraTriggerFallingEdge]", true);
    devPort.set("EventNotification[CameraTriggerRisingEdge]", true);
    devPort.set("EventNotification[AllowNextCycle]", true);
    devPort.set("CycleTriggerSource", "StartCycle");
}

configure(grabbers[0]);
