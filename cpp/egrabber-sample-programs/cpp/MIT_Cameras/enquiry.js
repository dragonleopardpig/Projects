// my_device.js
// run gentl script my_device.js

console.log("grabbers.length:", grabbers.length);

// // DevicePort
// if (grabbers.length) {
//     var port = grabbers[0].DevicePort;
    
//     var attrs = [
// 	"CameraControlMethod",
// 	"ExposureReadoutOverlap",
// 	"StrobeDuration",
// 	"C2CLinkConfiguration",
// 	"CycleTriggerSource",
// 	"StartOfSequenceTriggerSource",
// 	"EndOfSequenceTriggerSource",
// 	"SequenceLength",
// 	"EventNotification[CameraTriggerFallingEdge]",
// 	"EventNotification[CameraTriggerRisingEdge]"
//     ];

//     var vals = [
// 	"RG",
// 	"True",
// 	"10",
// 	"Disconnected",
// 	"Immediate",
// 	"Immediate",
// 	"SequenceLength",
// 	"1",
// 	"True",
// 	"True"
//     ];

//     if (port) {
// 	var i;
// 	for (i = 0;i < 10; i++) {
// 	    console.log(attrs[i] + "Value: " + port.get(attrs[i]));
// 	}
//     }
// }

// //InterfacePort
// if (grabbers.length) {
//     var port = grabbers[0].InterfacePort;
    
//     var attrs = [
// 	"LineSelector",
// 	"LineMode",
// 	"LineSource[TTLIO11]",
// 	"LineMode[IIN11]",
// 	"LineInputToolSource[LIN1]",
// 	"LineInputToolActivation[LIN1]"
//     ];

//     var vals = [
// 	"TTLIO11",
// 	"Output",
// 	"Device0Strobe",
// 	"Input",
// 	"IIN11",
// 	"RisingEdge"
//     ];

//     if (port) {
// 	var i;
// 	for (i = 0;i < 6; i++) {
// 	    console.log(attrs[i] + "Value: " + port.get(attrs[i]));
// 	}
//     }
// }

// //RemotePort
// if (grabbers.length) {
//     var port = grabbers[0].RemotePort;
//     var WidthMax = port.get("WidthMax");
//     var HeightMax = port.get("HeightMax");
    
//     var attrs = [
// 	"ReverseX",
// 	"ReverseY",
// 	"OffsetX",
// 	"OffsetY",
// 	"Width",
// 	"Height",
// 	"BinningHorizontal",
// 	"BinningVertical",
// 	"Gain",
// 	"ConnectionConfig",
// 	"PixelFormat",
// 	"TriggerSource",
// 	"TriggerActivation",
// 	"ExposureMode"
//     ];

//     var vals = [
// 	"False",
// 	"False",
// 	"0",
// 	"0",
// 	WidthMax,
// 	HeightMax,
// 	"1",
// 	"1",
// 	"1",
// 	"CXP6_X1",
// 	"Mono8",
// 	"Trigger",
// 	"RisingEdge",
// 	"TriggerWidth"
//     ];

//     if (port) {
// 	var i;
// 	for (i = 0;i < 14; i++) {
// 	    console.log(attrs[i] + "Value: " + port.get(attrs[i]));
// 	}
//     }
// }

// DevicePort
if (grabbers.length) {
    var port = grabbers[1].TLPort;
    
    var attrs = [
	"TLVendorName",
	"TLModelName",
	"TLID",
	"TLVersion",
	"TLPath",
	"TLType",
	"GenTLVersionMajor",
	"GenTLVersionMinor"
    ];

    if (port) {
	for (var i in attrs) {
	    console.log(attrs[i] + ": " + port.get(attrs[i]));
	}
    }
}

//InterfacePort
if (grabbers.length) {
    var port = grabbers[1].InterfacePort;
    
    var attrs = [
	"InterfaceID",
	"InterfaceType",
	"ProductCode",
	"SerialNumber",
	"PartNumber",
	"FirmwareRevision",
	"FirmwareVariant",
	"FirmwareStatus",
	"DeviceID",
	"DeviceVendorName",
	"DeviceAccessStatus"
    ];

    if (port) {
	for (var i in attrs) {
	    console.log(attrs[i] + ": " + port.get(attrs[i]));
	}
    }
}
