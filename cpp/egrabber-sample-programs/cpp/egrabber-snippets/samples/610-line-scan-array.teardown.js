function disableStreamEvents(p) {
    p.set('EventSelector', 'EndOfScan');
    p.set('EventNotification', false);
}

function configure(grabber) {
    disableStreamEvents(grabber.StreamPort);
}

configure(grabbers[0]);
