var g = grabbers[0];

// Declare virtual features on each module
g.DevicePort.declare("integer", "jsOne");
g.RemotePort.declare("float", "jsTwo");
g.StreamPort.declare("string", "jsThree");

// Set newly declared vitrual features
g.DevicePort.set("$jsOne", 1);
g.RemotePort.set("$jsTwo", 2.0);
g.StreamPort.set("$jsThree", 'three');
