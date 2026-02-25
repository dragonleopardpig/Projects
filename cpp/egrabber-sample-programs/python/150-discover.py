"""Discover and create eGrabbers or cameras with EGrabberDiscovery"""

from egrabber import *

def grab(grabber, N):
    grabber.realloc_buffers(N)
    grabber.start(N)
    for frame in range(N):
        with Buffer(grabber, timeout=1000) as buffer:
            print(' - Got frame {}: {}x{} {}'.format(
                frame,
                buffer.get_info(BUFFER_INFO_WIDTH, INFO_DATATYPE_SIZET),
                buffer.get_info(BUFFER_INFO_HEIGHT, INFO_DATATYPE_SIZET),
                gentl.image_get_pixel_format(buffer.get_info(BUFFER_INFO_PIXELFORMAT, INFO_DATATYPE_UINT64))))

plural = lambda n: 's' if n > 1 else ''


gentl = EGenTL()
discovery = EGrabberDiscovery(gentl)

print('Scanning the system for available eGrabbers and cameras')
discovery.discover()
print('')

interface_count = discovery.interface_count()
print('Found {} interface{} in the system'.format(interface_count, plural(interface_count)))
for interface_index in range(interface_count):
    iface = discovery.interface_info(interface_index)
    device_count = discovery.device_count(interface_index)
    print(' - Found {} device{} in {}'.format(device_count, plural(device_count), iface.interfaceID))
    for device_index in range(device_count):
        dev = discovery.device_info(interface_index, device_index)
        stream_count = discovery.stream_count(interface_index, device_index)
        print('   - Found {} stream{} in {}'.format(stream_count, plural(stream_count), dev.deviceID))
        for stream_index in range(stream_count):
            stream = discovery.stream_info(interface_index, device_index, stream_index)
            print('     - {}'.format(stream.streamID))
print('')

egrabber_count = len(discovery.egrabbers)
print('Discovered {} eGrabber{}'.format(egrabber_count, plural(egrabber_count)))
if egrabber_count > 0:
    print('Using the first one (egrabbers[0])')
    info = discovery.egrabbers[0]
    print('Camera model name: {}'.format(info.deviceModelName))
    grab(EGrabber(info), 3)
print('')

camera_count = len(discovery.cameras)
print('Discovered {} camera{}'.format(camera_count, plural(camera_count)))
if camera_count > 0:
    print('Using the first one (cameras[0])')
    info = discovery.cameras[0]
    if len(info.grabbers) > 1:
        print('This is a multi-bank camera composed by {} grabbers'.format(len(info.grabbers)))
    print('Camera model name: {}'.format(info.grabbers[0].deviceModelName))
    grab(EGrabber(info), 3)
print('')
