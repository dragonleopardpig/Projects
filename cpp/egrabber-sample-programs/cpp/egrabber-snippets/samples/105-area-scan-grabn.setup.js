//-- Setup Adimec N-5A100-Gm for area scan (CXP6_X1, RG mode)

function configure(grabber)
{
	//-- Grabber Settings (DevicePort)
	grabber.DevicePort.set("CameraControlMethod", "RG");
	grabber.DevicePort.set("ExposureReadoutOverlap", "True");
	grabber.DevicePort.set("StrobeDuration", "10");
	grabber.DevicePort.set("CycleTriggerSource", "Immediate");
	grabber.DevicePort.set("StartOfSequenceTriggerSource", "Immediate");
	grabber.DevicePort.set("EndOfSequenceTriggerSource", "SequenceLength");
	grabber.DevicePort.set("SequenceLength", "20");

	//-- Camera Settings (RemotePort)
	grabber.RemotePort.set("ConnectionConfig", "CXP6_X1");
	grabber.RemotePort.set("PixelFormat", "Mono8");
	grabber.RemotePort.set("TriggerSource", "Trigger");
	grabber.RemotePort.set("TriggerActivation", "RisingEdge");
	grabber.RemotePort.set("ExposureMode", "TriggerWidth");

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
}

configure(grabbers[0]);
