function configure(g) {
    // Image Format Control
    g.RemotePort.set('Width', 5120);
    g.RemotePort.set('Height', 5120);
    g.RemotePort.set('PixelFormat', 'Mono8');
    // Transport Layer Control
    g.RemotePort.set('DeviceTapGeometry', 'Geometry_1X8_1Y');
    
    // Camera Model
    g.DevicePort.set('CameraControlMethod', 'NC');
}

configure(grabbers[0]);
