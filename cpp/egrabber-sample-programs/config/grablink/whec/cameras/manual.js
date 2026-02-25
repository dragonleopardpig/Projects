var pl3r1500 = require('egrabber://cameras/whec/pl3r1500.js');

function discovery(g) {
    var sn = g.InterfacePort.get('SerialNumber'); // GDU<NNNNN>
    var did = g.DevicePort.get('DeviceID');       // Device<N>
    var id = [sn,did].join('/');                  // GDU<NNNNN>/Device<N>
    var expected = { 'GDU00457/Device0': { cameraId: 'CIS1', order: 0 }
                   , 'GDU00457/Device1': { cameraId: 'CIS1', order: 1 }
                   , 'GDU00466/Device0': { cameraId: 'CIS1', order: 2 }
                   , 'GDU00466/Device1': { cameraId: 'CIS1', order: 3 }
                   , 'GDU00453/Device0': { cameraId: 'CIS2', order: 0 }
                   , 'GDU00453/Device1': { cameraId: 'CIS2', order: 1 }
                   , 'GDU00469/Device0': { cameraId: 'CIS2', order: 2 }
                   , 'GDU00469/Device1': { cameraId: 'CIS2', order: 3 }
                   };
    try {
        var found = expected[id];
        memento.notice(id + ' -> #' + found.order + ', ' + found.cameraId);
        return found;
    } catch (err) {
        var e = id + ' not found in ' + module.filename;
        memento.warning(e);
        throw e;
    }
}

module.exports = { ecamera: { discovery: discovery
                            , setup: pl3r1500.ecamera.setup
                            , configureAnnounce: pl3r1500.ecamera.configureAnnounce } };
