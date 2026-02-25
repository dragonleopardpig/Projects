function disableCxpInterfaceEvents(p) {
    for (var selector of p.$ee('EventSelector')) {
        if(/ConnectionDetectedCxp[A-Z]|ConnectionUndetectedCxp[A-Z]|Device\d+(Ready|Lost)/.test(selector)) {
            p.set('EventSelector', selector);
            p.set('EventNotification', false);
        }
    }
    p.execute("EventCountResetAll");
}

disableCxpInterfaceEvents(grabbers[0].InterfacePort);
