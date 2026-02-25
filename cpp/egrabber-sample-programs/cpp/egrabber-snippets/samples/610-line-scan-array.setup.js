require('./config-sc.js');

function check(grabber) {
    if (!grabber.InterfacePort.get('InterfaceID').includes('line-scan')) {
        throw 'Expected line-scan grabber';
    }
}

function configureStream(grabber) {
    var p = grabber.StreamPort;
    p.set('StartOfScanTriggerSource', 'StartScan');
    p.set('EndOfScanTriggerSource', 'ScanLength');
    p.set('ScanLength', 1100);
    p.set('BufferHeight', 500);
    // configure events
    p.set('EventSelector', 'EndOfScan');
    p.set('EventNotification', true);
    p.set('EventNotificationContext1', 'EndOfScanEventCount');
    p.execute('EventCountReset');
}

function configure(grabber) {
    try {
        check(grabber);
        configureStream(grabber);
    }
    catch (e) {
        console.log('Script configuration error: ' + e);
        throw e;
    }
}

configure(grabbers[0]);
