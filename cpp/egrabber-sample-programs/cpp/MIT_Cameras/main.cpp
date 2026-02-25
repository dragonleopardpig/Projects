#include <iostream>
#include <EGrabber.h>
// #include <string>
// using namespace std;

void configure() {

  Euresys::EGenTL gentl;
  Euresys::EGrabber<> grabber(gentl);

  grabber.runScript("my_grabber.js");

  // // Set Manually
  // string WidthMax = grabber.getString<Euresys::RemoteModule>("WidthMax");
  // string HeightMax = grabber.getString<Euresys::RemoteModule>("HeightMax");

  // //--Grabber Settings
  // std::cout << "Old CameraControlMethod: " << grabber.getString<Euresys::DeviceModule>("CameraControlMethod") << "\n";
  // grabber.setString<Euresys::DeviceModule>("CameraControlMethod", "RG");
  // std::cout << "New CameraControlMethod: " << grabber.getString<Euresys::DeviceModule>("CameraControlMethod") << "\n";

  // std::cout << "Old ExposureReadoutOverlap: " << grabber.getString<Euresys::DeviceModule>("ExposureReadoutOverlap") << "\n";
  // grabber.setString<Euresys::DeviceModule>("ExposureReadoutOverlap", "True");
  // std::cout << "New ExposureReadoutOverlap: " << grabber.getString<Euresys::DeviceModule>("ExposureReadoutOverlap") << "\n";

  // std::cout << "Old StrobeDuration: " << grabber.getString<Euresys::DeviceModule>("StrobeDuration") << "\n";
  // grabber.setString<Euresys::DeviceModule>("StrobeDuration", "10");
  // std::cout << "New StrobeDuration: " << grabber.getString<Euresys::DeviceModule>("StrobeDuration") << "\n";

  // std::cout << "Old C2CLinkConfiguration: " << grabber.getString<Euresys::DeviceModule>("C2CLinkConfiguration") << "\n";
  // grabber.setString<Euresys::DeviceModule>("C2CLinkConfiguration", "Disconnected");
  // std::cout << "New C2CLinkConfiguration: " << grabber.getString<Euresys::DeviceModule>("C2CLinkConfiguration") << "\n";

  // std::cout << "Old CycleTriggerSource: " << grabber.getString<Euresys::DeviceModule>("CycleTriggerSource") << "\n";
  // grabber.setString<Euresys::DeviceModule>("CycleTriggerSource", "Immediate");
  // std::cout << "New CycleTriggerSource: " << grabber.getString<Euresys::DeviceModule>("CycleTriggerSource") << "\n";

  // std::cout << "Old StartOfSequenceTriggerSource: " << grabber.getString<Euresys::DeviceModule>("StartOfSequenceTriggerSource") << "\n";
  // grabber.setString<Euresys::DeviceModule>("StartOfSequenceTriggerSource", "Immediate");
  // std::cout << "New StartOfSequenceTriggerSource: " << grabber.getString<Euresys::DeviceModule>("StartOfSequenceTriggerSource") << "\n";

  // std::cout << "Old EndOfSequenceTriggerSource: " << grabber.getString<Euresys::DeviceModule>("EndOfSequenceTriggerSource") << "\n";
  // grabber.setString<Euresys::DeviceModule>("EndOfSequenceTriggerSource", "SequenceLength");
  // std::cout << "New EndOfSequenceTriggerSource: " << grabber.getString<Euresys::DeviceModule>("EndOfSequenceTriggerSource") << "\n";

  // std::cout << "Old SequenceLength: " << grabber.getString<Euresys::DeviceModule>("SequenceLength") << "\n";
  // grabber.setString<Euresys::DeviceModule>("SequenceLength", "1");
  // std::cout << "New SequenceLength: " << grabber.getString<Euresys::DeviceModule>("SequenceLength") << "\n";

  // std::cout << "Old EventNotification[CameraTriggerFallingEdge]: " << grabber.getString<Euresys::DeviceModule>("EventNotification[CameraTriggerFallingEdge]") << "\n";
  // grabber.setString<Euresys::DeviceModule>("EventNotification[CameraTriggerFallingEdge]", "True");
  // std::cout << "New EventNotification[CameraTriggerFallingEdge]: " << grabber.getString<Euresys::DeviceModule>("EventNotification[CameraTriggerFallingEdge]") << "\n";

  // std::cout << "Old EventNotification[CameraTriggerRisingEdge]: " << grabber.getString<Euresys::DeviceModule>("EventNotification[CameraTriggerRisingEdge]") << "\n";
  // grabber.setString<Euresys::DeviceModule>("EventNotification[CameraTriggerRisingEdge]", "True");
  // std::cout << "New EventNotification[CameraTriggerRisingEdge]: " << grabber.getString<Euresys::DeviceModule>("EventNotification[CameraTriggerRisingEdge]") << "\n";

  // std::cout << "Old LineSelector: " << grabber.getString<Euresys::InterfaceModule>("LineSelector") << "\n";
  // grabber.setString<Euresys::InterfaceModule>("LineSelector", "TTLIO11");
  // std::cout << "New LineSelector: " << grabber.getString<Euresys::InterfaceModule>("LineSelector") << "\n";

  // std::cout << "Old LineMode: " << grabber.getString<Euresys::InterfaceModule>("LineMode") << "\n";
  // grabber.setString<Euresys::InterfaceModule>("LineMode", "Output");
  // std::cout << "New LineMode: " << grabber.getString<Euresys::InterfaceModule>("LineMode") << "\n";

  // std::cout << "Old LineSource[TTLIO11]: " << grabber.getString<Euresys::InterfaceModule>("LineSource[TTLIO11]") << "\n";
  // grabber.setString<Euresys::InterfaceModule>("LineSource[TTLIO11]", "Device0Strobe");
  // std::cout << "New LineSource[TTLIO11]: " << grabber.getString<Euresys::InterfaceModule>("LineSource[TTLIO11]") << "\n";

  // std::cout << "Old LineMode[IIN11]: " << grabber.getString<Euresys::InterfaceModule>("LineMode[IIN11]") << "\n";
  // grabber.setString<Euresys::InterfaceModule>("LineMode[IIN11]", "Input");
  // std::cout << "New LineMode[IIN11]: " << grabber.getString<Euresys::InterfaceModule>("LineMode[IIN11]") << "\n";

  // std::cout << "Old LineInputToolSource[LIN1]: " << grabber.getString<Euresys::InterfaceModule>("LineInputToolSource[LIN1]") << "\n";
  // grabber.setString<Euresys::InterfaceModule>("LineInputToolSource[LIN1]", "IIN11");
  // std::cout << "New LineInputToolSource[LIN1]: " << grabber.getString<Euresys::InterfaceModule>("LineInputToolSource[LIN1]") << "\n";

  // std::cout << "Old LineInputToolActivation[LIN1]: " << grabber.getString<Euresys::InterfaceModule>("LineInputToolActivation[LIN1]") << "\n";
  // grabber.setString<Euresys::InterfaceModule>("LineInputToolActivation[LIN1]", "RisingEdge");
  // std::cout << "New LineInputToolActivation[LIN1]: " << grabber.getString<Euresys::InterfaceModule>("LineInputToolActivation[LIN1]") << "\n";

  // std::cout << "Old ReverseX: " << grabber.getString<Euresys::RemoteModule>("ReverseX") << "\n";
  // grabber.setString<Euresys::RemoteModule>("ReverseX", "False");
  // std::cout << "New ReverseX: " << grabber.getString<Euresys::RemoteModule>("ReverseX") << "\n";

  // std::cout << "Old ReverseY: " << grabber.getString<Euresys::RemoteModule>("ReverseY") << "\n";
  // grabber.setString<Euresys::RemoteModule>("ReverseY", "False");
  // std::cout << "New ReverseY: " << grabber.getString<Euresys::RemoteModule>("ReverseY") << "\n";

  // std::cout << "Old OffsetX: " << grabber.getString<Euresys::RemoteModule>("OffsetX") << "\n";
  // grabber.setString<Euresys::RemoteModule>("OffsetX", "0");
  // std::cout << "New OffsetX: " << grabber.getString<Euresys::RemoteModule>("OffsetX") << "\n";

  // std::cout << "Old OffsetY: " << grabber.getString<Euresys::RemoteModule>("OffsetY") << "\n";
  // grabber.setString<Euresys::RemoteModule>("OffsetY", "0");
  // std::cout << "New OffsetY: " << grabber.getString<Euresys::RemoteModule>("OffsetY") << "\n";

  // std::cout << "Old WidthMax: " << grabber.getString<Euresys::RemoteModule>("WidthMax") << "\n";
  // grabber.setString<Euresys::RemoteModule>("Width", WidthMax);
  // std::cout << "New  WidthMax: " << grabber.getString<Euresys::RemoteModule>("WidthMax") << "\n";

  // std::cout << "Old HeightMax: " << grabber.getString<Euresys::RemoteModule>("HeightMax") << "\n";
  // grabber.setString<Euresys::RemoteModule>("Height", HeightMax);
  // std::cout << "New HeightMax: " << grabber.getString<Euresys::RemoteModule>("HeightMax") << "\n";

  // std::cout << "Old BinningHorizontal: " << grabber.getString<Euresys::RemoteModule>("BinningHorizontal") << "\n";
  // grabber.setString<Euresys::RemoteModule>("BinningHorizontal", "1");
  // std::cout << "New BinningHorizontal: " << grabber.getString<Euresys::RemoteModule>("BinningHorizontal") << "\n";

  // std::cout << "Old BinningVertical: " << grabber.getString<Euresys::RemoteModule>("BinningVertical") << "\n";
  // grabber.setString<Euresys::RemoteModule>("BinningVertical", "1");
  // std::cout << "New BinningVertical: " << grabber.getString<Euresys::RemoteModule>("BinningVertical") << "\n";

  // std::cout << "Old Gain: " << grabber.getString<Euresys::RemoteModule>("Gain") << "\n";
  // grabber.setString<Euresys::RemoteModule>("Gain", "1");
  // std::cout << "New Gain: " << grabber.getString<Euresys::RemoteModule>("Gain") << "\n";

  // std::cout << "Old ConnectionConfig: " << grabber.getString<Euresys::RemoteModule>("ConnectionConfig") << "\n";
  // grabber.setString<Euresys::RemoteModule>("ConnectionConfig", "CXP6_X1");
  // std::cout << "New ConnectionConfig: " << grabber.getString<Euresys::RemoteModule>("ConnectionConfig") << "\n";

  // std::cout << "Old PixelFormat: " << grabber.getString<Euresys::RemoteModule>("PixelFormat") << "\n";
  // grabber.setString<Euresys::RemoteModule>("PixelFormat", "Mono8");
  // std::cout << "New PixelFormat: " << grabber.getString<Euresys::RemoteModule>("PixelFormat") << "\n";

  // std::cout << "Old TriggerSource: " << grabber.getString<Euresys::RemoteModule>("TriggerSource") << "\n";
  // grabber.setString<Euresys::RemoteModule>("TriggerSource", "Trigger");
  // std::cout << "New TriggerSource: " << grabber.getString<Euresys::RemoteModule>("TriggerSource") << "\n";

  // std::cout << "Old TriggerActivation: " << grabber.getString<Euresys::RemoteModule>("TriggerActivation") << "\n";
  // grabber.setString<Euresys::RemoteModule>("TriggerActivation", "RisingEdge");
  // std::cout << "New TriggerActivation: " << grabber.getString<Euresys::RemoteModule>("TriggerActivation") << "\n";

  // std::cout << "Old ExposureMode: " << grabber.getString<Euresys::RemoteModule>("ExposureMode") << "\n";
  // grabber.setString<Euresys::RemoteModule>("ExposureMode", "TriggerWidth");
  // std::cout << "New ExposureMode: " << grabber.getString<Euresys::RemoteModule>("ExposureMode") << "\n";
}

int main() {
  try {
    configure();
  } catch (const std::exception &e) {
    std::cout << "error: " << e.what() << std::endl;
  }
}
