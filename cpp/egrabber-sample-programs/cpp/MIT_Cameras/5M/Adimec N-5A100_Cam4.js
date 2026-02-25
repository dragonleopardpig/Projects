//--Setup Adimec N-5A100-Gm


function configure(grabber)
{
	//--Grabber Settings
	grabber.DevicePort.set("CxpLinkConfiguration", "CXP6_X1");
	grabber.DevicePort.set("CameraControlMethod", "RG");
	grabber.DevicePort.set("ExposureReadoutOverlap", "False");

	grabber.DevicePort.set("StrobeDuration", "10");
	grabber.DevicePort.set("C2CLinkConfiguration", "Disconnected");
	grabber.DevicePort.set("CycleTriggerSource", "Immediate");
	grabber.DevicePort.set("StartOfSequenceTriggerSource", "Immediate");
	grabber.DevicePort.set("EndOfSequenceTriggerSource", "SequenceLength");
	grabber.DevicePort.set("SequenceLength", "1");
	grabber.DevicePort.set("EventNotification[CameraTriggerFallingEdge]", true);
	grabber.DevicePort.set("EventNotification[CameraTriggerRisingEdge]", true);

	grabber.InterfacePort.set("LineSelector", "TTLIO12");
	grabber.InterfacePort.set("LineMode", "Output");
	grabber.InterfacePort.set("LineSource[TTLIO12]", "Device1Strobe");

	grabber.InterfacePort.set("LineMode[IIN12]", "Input");
	grabber.InterfacePort.set("LineInputToolSource[LIN2]", "IIN12");
	grabber.InterfacePort.set("LineInputToolActivation[LIN2]", "RisingEdge");

	grabber.RemotePort.set("OffsetX", "0");
	grabber.RemotePort.set("OffsetY", "0");

	var WidthMax = grabber.RemotePort.get("WidthMax");
	var HeightMax = grabber.RemotePort.get("HeightMax");

	grabber.RemotePort.set("Width", WidthMax);
	grabber.RemotePort.set("Height", HeightMax);

	grabber.RemotePort.set("BinningHorizontal", "1");
	grabber.RemotePort.set("BinningVertical", "1");

	grabber.RemotePort.set("Gain", "4.0");


    grabber.RemotePort.set("ConnectionConfig", "CXP6_X1");
	grabber.RemotePort.set("PixelFormat", "Mono8");
	grabber.RemotePort.set("TriggerSource", "Trigger");
	grabber.RemotePort.set("TriggerActivation", "RisingEdge");
	grabber.RemotePort.set("ExposureMode", "TriggerWidth");

}

configure(grabbers[0]);

