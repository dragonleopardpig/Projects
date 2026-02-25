require('./config-rg.js');

function selectCxpInterfaceEvents(p) {
    for (var selector of p.$ee('EventSelector')) {
        if(/ConnectionDetectedCxp[A-Z]|ConnectionUndetectedCxp[A-Z]|Device\d+(Ready|Lost)/.test(selector)) {
            p.set('EventSelector', selector);
            p.set('EventNotification', true);
        }
    }
}

selectCxpInterfaceEvents(grabbers[0].InterfacePort);
