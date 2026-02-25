"""Write to a Recorder container using EGrabber callback"""

import os
from egrabber import *
from egrabber.recorder import *

buffer_count = 20
recorder_full = False

def allocate_buffers(grabber, buffer_count):
    alignment = recorder.get(RECORDER_PARAMETER_BUFFER_OPTIMAL_ALIGNMENT)
    grabber.stream.set('BufferAllocationAlignmentControl', 'Enable')
    grabber.stream.set('BufferAllocationAlignment', alignment)
    grabber.realloc_buffers(buffer_count)

def on_new_buffer_event(grabber, data, _):
    global buffer_count
    global recorder_full
    with Buffer(grabber, data) as buffer:
        info = RECORDER_BUFFER_INFO(
            size        = buffer.get_info(BUFFER_INFO_SIZE, INFO_DATATYPE_SIZET),
            pitch       = buffer.get_info(BUFFER_INFO_CUSTOM_LINE_PITCH, INFO_DATATYPE_SIZET),
            width       = buffer.get_info(BUFFER_INFO_WIDTH, INFO_DATATYPE_SIZET),
            height      = buffer.get_info(BUFFER_INFO_DELIVERED_IMAGEHEIGHT, INFO_DATATYPE_SIZET),
            pixelformat = buffer.get_info(BUFFER_INFO_PIXELFORMAT, INFO_DATATYPE_UINT64),
            partCount   = buffer.get_info(BUFFER_INFO_CUSTOM_NUM_PARTS, INFO_DATATYPE_SIZET),
            partSize    = buffer.get_info(BUFFER_INFO_CUSTOM_PART_SIZE, INFO_DATATYPE_SIZET),
            timestamp   = buffer.get_info(BUFFER_INFO_TIMESTAMP_NS, INFO_DATATYPE_UINT64))
        base = buffer.get_info(BUFFER_INFO_BASE, INFO_DATATYPE_PTR)
        
        try:
            recorder.write(info, to_cchar_array(base, info.size))
        except DataFileFull:
            print('container full')
            recorder_full = True
        except RecorderError as e:
            raise e

def get_container_path():
    container_path = '{}/{}.output'.format(os.getenv('OUTPUT_DIR', os.path.dirname(__file__)), os.path.splitext(os.path.basename(__file__))[0])
    if not os.path.isdir(container_path):
        os.makedirs(container_path)
    return container_path

gentl = EGenTL()
recorder_lib = RecorderLibrary()

container_path = get_container_path()

recorder = recorder_lib.open_recorder(container_path, RECORDER_OPEN_MODE_WRITE, RECORDER_CLOSE_MODE_KEEP)
recorder.set(RECORDER_PARAMETER_CONTAINER_SIZE, 100 * 1024 * 1024)

grabber = EGrabber(gentl)
allocate_buffers(grabber, buffer_count)
grabber.on_new_buffer_event = on_new_buffer_event

grabber.start()
while not recorder_full:
    try:
        grabber.process_event([NewBufferData], 100)
    except TimeoutException:
        pass

grabber.stop()

print('Record count in container: {}'.format(recorder.get(RECORDER_PARAMETER_RECORD_COUNT)))
print('Remaining space in container: {}'.format(recorder.get(RECORDER_PARAMETER_REMAINING_SPACE_IN_CONTAINER)))
