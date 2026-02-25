"""Write/Read buffers to/from a Recorder container"""

import os
from egrabber import *
from egrabber.recorder import *

def process_recorded_buffer(info, data):
    # processing code
    pass

def write_recorder(gentl, recorder_lib, container_path):
    recorder = recorder_lib.open_recorder(container_path, RECORDER_OPEN_MODE_WRITE)
    grabber = EGrabber(gentl)
    
    alignment = recorder.get(RECORDER_PARAMETER_BUFFER_OPTIMAL_ALIGNMENT)
    grabber.stream.set('BufferAllocationAlignmentControl', 'Enable')
    grabber.stream.set('BufferAllocationAlignment', alignment)

    N = 10
    recorder.set(RECORDER_PARAMETER_CONTAINER_SIZE, N * grabber.get_payload_size())

    grabber.realloc_buffers(3)
    grabber.start(N)
    for frame in range(N):
        with Buffer(grabber) as buffer:
            info = RECORDER_BUFFER_INFO()
            info.size = buffer.get_info(BUFFER_INFO_SIZE, INFO_DATATYPE_SIZET)
            info.pitch = buffer.get_info(BUFFER_INFO_CUSTOM_LINE_PITCH, INFO_DATATYPE_SIZET)
            info.width = buffer.get_info(BUFFER_INFO_WIDTH, INFO_DATATYPE_SIZET)
            info.height = buffer.get_info(BUFFER_INFO_DELIVERED_IMAGEHEIGHT, INFO_DATATYPE_SIZET)
            info.pixelformat = buffer.get_info(BUFFER_INFO_PIXELFORMAT, INFO_DATATYPE_UINT64)
            info.partCount = buffer.get_info(BUFFER_INFO_CUSTOM_NUM_PARTS, INFO_DATATYPE_SIZET)
            info.partSize = buffer.get_info(BUFFER_INFO_CUSTOM_PART_SIZE, INFO_DATATYPE_SIZET)
            info.timestamp = buffer.get_info(BUFFER_INFO_TIMESTAMP_NS, INFO_DATATYPE_UINT64)
            info.userdata = frame

            base = buffer.get_info(BUFFER_INFO_BASE, INFO_DATATYPE_PTR)
            recorder.write(info, to_cchar_array(base, info.size))
            print('Buffer #{} ({}x{} {}, userdata={}) has been written to the container'.format(frame, info.width, info.height, gentl.image_get_pixel_format(info.pixelformat), info.userdata))

def read_recorder(gentl, recorder_lib, container_path):
    recorder = recorder_lib.open_recorder(container_path, RECORDER_OPEN_MODE_READ)
    count = recorder.get(RECORDER_PARAMETER_RECORD_COUNT)

    for i in range(count):
        (buffer, info) = recorder.read()
        print('Buffer #{} ({}x{} {}, userdata={}) has been read from the container'.format(i, info.width, info.height, gentl.image_get_pixel_format(info.pixelformat), info.userdata))
        process_recorded_buffer(info, buffer)

def get_container_path():
    container_path = '{}/{}.output'.format(os.getenv('OUTPUT_DIR', os.path.dirname(__file__)), os.path.splitext(os.path.basename(__file__))[0])
    if not os.path.isdir(container_path):
        os.makedirs(container_path)
    return container_path

if __name__ == '__main__':
    gentl = EGenTL()
    recorder_lib = RecorderLibrary()
    container_path = get_container_path()
    write_recorder(gentl, recorder_lib, container_path)
    read_recorder(gentl, recorder_lib, container_path)
