require('./config-rg.js');

function enableAllEvents(p) {
    console.log("enableAllEvents on " + p.name);
    for (var selector of p.$ee('EventSelector')) {
        console.log("  " + selector);
        p.set('EventSelector', selector);
        p.set('EventNotification', 'True');
        p.set('EventNotificationContext1', 'EventSpecific');
        p.set('EventNotificationContext2', 'LineStatusAll');
        p.set('EventNotificationContext3', selector + 'EventCount');
        p.execute('EventCountReset');
    }
}

function configure(grabber) {
    enableAllEvents(grabber.InterfacePort);
    enableAllEvents(grabber.DevicePort);
    enableAllEvents(grabber.StreamPort);
}

configure(grabbers[0]);
