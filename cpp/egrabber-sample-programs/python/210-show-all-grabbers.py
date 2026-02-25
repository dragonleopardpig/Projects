"""Show available grabbers"""

from egrabber import *

def show(index, portname, name, getter):
    print('grabber[{}].{}.{} = {}'.format(index, portname, name, getter(name)))

def showGrabbers(grabbers):
    for (index, grabber) in enumerate(grabbers):
        show(index, 'InterfacePort', 'InterfaceID', grabber.interface.get)
        show(index, 'DevicePort', 'DeviceID', grabber.device.get)
        if grabber.remote is not None:
            show(index, 'RemotePort', 'DeviceVendorName', grabber.remote.get)
            show(index, 'RemotePort', 'DeviceModelName', grabber.remote.get)
        show(index, 'StreamPort', 'StreamID', grabber.stream.get)

def createGrabbers(gentl):
    grabbers = []
    for interfaceIndex in range(4):
        for deviceIndex in range(8):
            for streamIndex in range(4):
                try:
                    grabbers.append(EGrabber(gentl, interfaceIndex, deviceIndex, streamIndex, remote_required=False))
                    message = 'Added Grabber[{}] on interface {} for device {} and stream {}'
                    print(message.format(len(grabbers) - 1, interfaceIndex, deviceIndex, streamIndex))
                except:
                    break
    return grabbers

gentl = EGenTL()
showGrabbers(createGrabbers(gentl))

