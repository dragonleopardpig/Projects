function disableAllEvents(p) {
    console.log("disableAllEvents on " + p.name);
    for (var selector of p.$ee('EventSelector')) {
        console.log("  " + selector);
        p.set('EventSelector', selector);
        p.set('EventNotification', 'False');
    }
}

function configure(grabber) {
    disableAllEvents(grabber.InterfacePort);
    disableAllEvents(grabber.DevicePort);
    disableAllEvents(grabber.StreamPort);
}

configure(grabbers[0]);
