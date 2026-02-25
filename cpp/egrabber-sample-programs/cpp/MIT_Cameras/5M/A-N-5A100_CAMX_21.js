//-- Setup Adimec N-5A100-Gm


function configure(grabber)
{
	//--Grabber Settings
	grabber.DevicePort.set("CameraControlMethod", "RG");
	grabber.DevicePort.set("ExposureReadoutOverlap", "True");

	grabber.DevicePort.set("StrobeDuration", "10");
	grabber.DevicePort.set("C2CLinkConfiguration", "Disconnected");
	grabber.DevicePort.set("CycleTriggerSource", "Immediate");
	grabber.DevicePort.set("StartOfSequenceTriggerSource", "Immediate");
	grabber.DevicePort.set("EndOfSequenceTriggerSource", "SequenceLength");
	grabber.DevicePort.set("SequenceLength", "1");
	grabber.DevicePort.set("EventNotification[CameraTriggerFallingEdge]", true);
	grabber.DevicePort.set("EventNotification[CameraTriggerRisingEdge]", true);

	grabber.InterfacePort.set("LineSelector", "TTLIO21");
	grabber.InterfacePort.set("LineMode", "Output");
	grabber.InterfacePort.set("LineSource[TTLIO21]", "Device2Strobe");
	grabber.InterfacePort.set("LineMode[IIN21]", "Input");
	grabber.InterfacePort.set("LineInputToolSource[LIN3]", "IIN21");
	grabber.InterfacePort.set("LineInputToolActivation[LIN3]", "RisingEdge");

	grabber.RemotePort.set("ReverseX", "False");
	grabber.RemotePort.set("ReverseY", "False");

	grabber.RemotePort.set("OffsetX", "0");
	grabber.RemotePort.set("OffsetY", "0");

	var WidthMax = grabber.RemotePort.get("WidthMax");
	var HeightMax = grabber.RemotePort.get("HeightMax");

	grabber.RemotePort.set("Width", WidthMax);
	grabber.RemotePort.set("Height", HeightMax);

	grabber.RemotePort.set("BinningHorizontal", "1");
	grabber.RemotePort.set("BinningVertical", "1");

	grabber.RemotePort.set("Gain", "1");
	
	grabber.RemotePort.set("ConnectionConfig", "CXP6_X1");
	grabber.RemotePort.set("PixelFormat", "Mono8");
	grabber.RemotePort.set("TriggerSource", "Trigger");
	grabber.RemotePort.set("TriggerActivation", "RisingEdge");
	grabber.RemotePort.set("ExposureMode", "TriggerWidth");

}

configure(grabbers[0]);

