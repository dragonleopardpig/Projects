var configure = require('egrabber://configurator.js');

var parameters = {
    OperatingMode:              "SC",
    AcquisitionMode:            "SingleFrame",
    ExposureTime:               5500
};
configure(grabbers[0], parameters);

grabbers[0].StreamPort.set('ControlRemoteDevice', 'False');
grabbers[0].RemotePort.set('ActionDeviceKey', 0xcafebabe);
grabbers[0].DevicePort.set('ActionDeviceKey', 0xcafebabe);
grabbers[0].RemotePort.set('ActionSelector', 1); // must match 'Action1' below.
grabbers[0].RemotePort.set('ActionGroupKey', 0x42);
grabbers[0].RemotePort.set('ActionGroupMask', 0xffffffff);
grabbers[0].DevicePort.set('ActionGroupKey', 0x42);
grabbers[0].DevicePort.set('ActionGroupMask', 0xffffffff);
// following parameters configure Action1 as frame trigger.
grabbers[0].RemotePort.set('TriggerSelector', "FrameStart");
grabbers[0].RemotePort.set('TriggerMode', "On");
grabbers[0].RemotePort.set('TriggerSource', 'Action1');
