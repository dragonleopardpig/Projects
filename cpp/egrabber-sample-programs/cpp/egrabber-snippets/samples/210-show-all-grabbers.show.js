function show(port, feature) {
    var value;
    if (port.has(feature)) {
        value = port.get(feature);
    }
    console.log('  ' + port.name + '.' + feature + ' = ' + value);
}

function showInfos(grabber) {
    show(grabber.InterfacePort, 'InterfaceID');
    show(grabber.DevicePort, 'DeviceID');
    show(grabber.RemotePort, 'DeviceVendorName');
    show(grabber.RemotePort, 'DeviceModelName');
}

showInfos(grabbers[0]);
