var grabber = grabbers[0];

var iid = grabber.InterfacePort.get('InterfaceID');
var did = grabber.DevicePort.get('DeviceID');
var sid = grabber.StreamPort.get('StreamID');

if (!/4-data-stream/.test(iid)) {
    throw '650-multistream is intended for "4-data-stream" firmware variants';
}

console.log('Executing ' + module.filename + ' on:');
console.log('- ' + iid);
console.log('- ' + did + '/' + sid);
