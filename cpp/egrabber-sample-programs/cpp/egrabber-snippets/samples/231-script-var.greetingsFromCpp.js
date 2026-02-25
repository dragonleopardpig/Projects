var g = grabbers[0];
console.log("From Script: <DeviceModule> $cppGreeting = " + g.DevicePort.get("$cppGreeting"));
console.log("From Script: <RemoteModule> $cppGreeting = " + g.RemotePort.get("$cppGreeting"));
console.log("From Script: <StreamModule> $cppGreeting = " + g.StreamPort.get("$cppGreeting"));
