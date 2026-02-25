// This file describes the 'grabbers' object of Euresys GenApi Script. It can
// be executed by running 'gentl script coaxlink://doc/grabbers.js'.

// The builtin object 'grabbers' is a list of objects giving access to the
// available GenTL modules/ports.

// In most cases, 'grabbers' contains exactly one element. However, when using
// the 'gentl script' command, 'grabbers' contains the list of all devices.
// This makes it possible to configure several cameras and/or cards.

console.log("grabbers.length:", grabbers.length);

// // Each item in 'grabbers' encapsulates all the ports related to one data
// // stream:
// //  TLPort          | GenTL producer
// //  InterfacePort   | Coaxlink card
// //  DevicePort      | local device
// //  StreamPort      | data stream
// //  RemotePort      | camera (if available)

var PortNames = ['TLPort', 'InterfacePort', 'DevicePort', 'StreamPort',
                 'RemotePort'];

// // Ports are objects which provide the following textual information:
// //  name            | one of PortNames
// //  tag             | port handle type and value (as shown in memento traces)

for (var i in grabbers) {
    var g = grabbers[i];
    console.log('- grabbers[' + i + ']');
    for (var pn of PortNames) {
        var port = g[pn];
        console.log('  - ' + port.name + ' (' + port.tag + ')');
    }
}

// // Ports also have the following functions to work on GenICam features:
// //  get(f)          | get value of f
// //  set(f,v)        | set value v to f
// //  execute(f)      | execute f
// //  features([re])  | get list of features [matching regular expression re]
// //  $features([re]) | strict* variant of features([re])
// //  ee(f,[re])      | get list of enum entries [matching regular expression re]
// //                  | of enumeration f
// //  $ee(f,[re])     | strict* variant of ee(f,[re])
// //  has(f)          | test if f exists
// //  has(f,v)        | test if f has an enum entry v
// //  available(f)    | test if f is available
// //  available(f,v)  | test if f has an enum entry v which is available
// //  selectors(f)    | get list of features that act as selectors of f
// //  attributes(...) | extract information from the XML file describing the port
// //
// // * by strict we mean that the returned list contains only nodes/values
// //   that are available (as dictated by 'pIsAvailable' GenICam node elements)

// if (grabbers.length) {
//     var port = grabbers[0].InterfacePort;
//     console.log('Playing with', port.tag);
//     // get(f)
//     console.log('- InterfaceID: ' + port.get('InterfaceID'));
//     // set(f,v)
//     port.set('LineSelector', 'TTLIO11');
//     // execute(f)
//     port.execute('DeviceUpdateList');
//     // features(re)
//     console.log('- Features matching \'PCIe\':');
//     for (var f of port.features('PCIe')) {
//         console.log('  - ' + f);
//     }
//     // $ee(f)
//     console.log('- Available enum entries for LineSource:');
//     for (var ee of port.$ee('LineSource')) {
//         console.log('  - ' + ee);
//     }
//     for (var ix of [0, 1, 2, 3, 9]) {
//         var ee = 'Device' + ix + 'Strobe';
//         // has(f, v)
//         if (port.has('LineSource', ee)) {
//             console.log('- ' + ee + ' exists');
//         } else {
//             console.log('- ' + ee + ' does not exist');
//         }
//         // available(f, v)
//         if (port.available('LineSource', ee)) {
//             console.log('- ' + ee + ' is available');
//         } else {
//             console.log('- ' + ee + ' is not available');
//         }
//     }
//     // selectors(f)
//     console.log('- LineSource feature is selected by',
//                 port.selectors('LineSource'));
//     // attributes()
//     console.log('- attributes()');
//     var attrs = port.attributes();
//     for (var n in attrs) {
//         console.log('  - ' + n + ': ' + attrs[n]);
//     }
//     // attributes(f)
//     console.log('- attributes(\'LineFormat\')');
//     var attrs = port.attributes('LineFormat');
//     for (var n in attrs) {
//         console.log('  - ' + n + ': ' + attrs[n]);
//     }
//     // attributes(f)
//     var fmt = port.get('LineFormat');
//     console.log('- attributes(\'LineFormat\', \'' + fmt + '\')');
//     var attrs = port.attributes('LineFormat', fmt);
//     for (var n in attrs) {
//         console.log('  - ' + n + ': ' + attrs[n]);
//     }
//     // optional suffixes to integer or float feature names
//     if (port.available('DividerToolSelector') &&
//         port.available('DividerToolSelector', 'DIV1')) {
//         var feature = 'DividerToolDivisionFactor[DIV1]';
//         var suffixes = ['.Min', '.Max', '.Inc', '.Value'];
//         console.log('- Accessing ' + suffixes + ' of ' + feature);
//         for (var suffix of suffixes) {
//             console.log( '  - ' + suffix + ': ' + port.get(feature + suffix));
//         }
//     }
// }

// // Camera ports (RemotePort) also have the following functions:
// //  brRead(addr)    | read bootstrap register (32-bit big endian)
// //  brWrite(addr,v) | write value to bootstrap register (32-bit big endian)

// if (grabbers.length) {
//     var port = grabbers[0].RemotePort;
//     if (port) {
//         console.log('Playing with', port.tag);
//         var brStandard = 0x00000000;
//         var brRevision = 0x00000004;
//         var standard = port.brRead(brStandard);
//         var revision = port.brRead(brRevision);
//         if (0xc0a79ae5 === standard) {
//             console.log('Bootstrap register "Standard" is OK (0xc0a79ae5)');
//         } else {
//             console.log('Bootstrap register "Standard" is ' + standard);
//         }
//         console.log('Bootstrap register "Revision" is ' + revision);
//     }
// }

if (grabbers.length) {
    var port = grabbers[0].DevicePort;

    var attrs = [
	"CameraControlMethod",
	"ExposureReadoutOverlap",
	"StrobeDuration",
	"C2CLinkConfiguration",
	"CycleTriggerSource",
	"StartOfSequenceTriggerSource",
	"EndOfSequenceTriggerSource",
	"SequenceLength",
	"EventNotification[CameraTriggerFallingEdge]",
	"EventNotification[CameraTriggerRisingEdge]"
    ];

    var vals = [
	"RG",
	"True",
	"10",
	"Disconnected",
	"Immediate",
	"Immediate",
	"SequenceLength",
	"1",
	"True",
	"True"
    ];

    if (port) {
	for (var i in attrs) {
	    console.log("Old " + attrs[i] + "Value: " + port.get(attrs[i]));
	    port.set(attrs[i], vals[i]);
	    console.log("New " + attrs[i] + "Value: " + port.get(attrs[i]));
	}
    }
}
