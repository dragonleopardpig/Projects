function fpsToMicroseconds(fps) {
    return 1e6 / fps;
}

function configure(g) {
    // Image Format Control
    g.RemotePort.set('Width', 5120);
    g.RemotePort.set('Height', 5120);
    g.RemotePort.set('PixelFormat', 'Mono8');
    // Transport Layer Control
    g.RemotePort.set('DeviceTapGeometry', 'Geometry_1X8_1Y');
    
    // Camera Model
    g.DevicePort.set('CameraControlMethod', 'RG');
    g.DevicePort.set('ExposureReadoutOverlap', true);
    g.DevicePort.set('ExposureRecoveryTime', 1000);
    g.DevicePort.set('CycleMinimumPeriod', fpsToMicroseconds(30));
    // Cycle Timing
    g.DevicePort.set('ExposureTime', 1000);
    g.DevicePort.set('StrobeDuration', 500);
    g.DevicePort.set('StrobeDelay', 250);
    // Cycle Control
    g.DevicePort.set('CycleTriggerSource', 'Immediate');
    // Camera Link
    g.DevicePort.set('CameraControlLineSelector', 'CC1');
    g.DevicePort.set('CameraControlLineSource', 'CameraTrigger');
    g.DevicePort.set('CameraControlLineInverter', false);
}

configure(grabbers[0]);
