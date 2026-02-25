var configure = require('egrabber://configurator.js');

var parameters = {
    OperatingMode:              "SC",
    ExposureTime:               5500
};

configure(grabbers[0], parameters);
