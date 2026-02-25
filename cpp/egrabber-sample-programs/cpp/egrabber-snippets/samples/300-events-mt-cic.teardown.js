function configure(grabber) {
    var devPort = grabber.DevicePort;
    devPort.set("EventNotification[CameraTriggerFallingEdge]", false);
    devPort.set("EventNotification[CameraTriggerRisingEdge]", false);
    devPort.set("EventNotification[AllowNextCycle]", false);
}

configure(grabbers[0]);
