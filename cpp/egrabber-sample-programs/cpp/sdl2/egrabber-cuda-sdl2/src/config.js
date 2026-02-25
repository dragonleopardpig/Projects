var grabber = grabbers[0];
var configure = require('egrabber://configurator.js');

var parameters = {
    OperatingMode:              "SC",
    ExposureTime:               5000
};

configure(grabber, parameters);

if (grabber.StreamPort.get("PixelFormat")  !== "RGB8") {
    grabber.RemotePort.set("PixelFormat", "RGB8");
}
