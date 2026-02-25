"""Show Recorder parameters"""

import os
from egrabber.recorder import *

def show_recorder_parameters(recorder):
    print('Recorder parameters')
    print('-------------------')
    print('- RECORDER_PARAMETER_VERSION: ',                       recorder.get(RECORDER_PARAMETER_VERSION))
    print('- RECORDER_PARAMETER_CONTAINER_SIZE: ',                recorder.get(RECORDER_PARAMETER_CONTAINER_SIZE))
    print('- RECORDER_PARAMETER_RECORD_INDEX: ',                  recorder.get(RECORDER_PARAMETER_RECORD_INDEX))
    print('- RECORDER_PARAMETER_RECORD_COUNT: ',                  recorder.get(RECORDER_PARAMETER_RECORD_COUNT))
    print('- RECORDER_PARAMETER_REMAINING_SPACE_ON_DEVICE: ',     recorder.get(RECORDER_PARAMETER_REMAINING_SPACE_ON_DEVICE))
    print('- RECORDER_PARAMETER_BUFFER_OPTIMAL_ALIGNMENT: ',      recorder.get(RECORDER_PARAMETER_BUFFER_OPTIMAL_ALIGNMENT))
    print('- RECORDER_PARAMETER_DATABASE_VERSION: ',              recorder.get(RECORDER_PARAMETER_DATABASE_VERSION))
    print('- RECORDER_PARAMETER_REMAINING_SPACE_IN_CONTAINER: ',  recorder.get(RECORDER_PARAMETER_REMAINING_SPACE_IN_CONTAINER))

def get_container_path():
    container_path = '{}/{}.output'.format(os.getenv('OUTPUT_DIR', os.path.dirname(__file__)), os.path.splitext(os.path.basename(__file__))[0])
    if not os.path.isdir(container_path):
        os.makedirs(container_path)
    return container_path

recorder_lib = RecorderLibrary()
container_path = get_container_path()

print('Create a recorder for writing with automatic trim on close')
with recorder_lib.open_recorder(container_path, RECORDER_OPEN_MODE_WRITE) as recorder:

    print('Allocate recorder container space for 1000000 bytes')
    recorder.set(RECORDER_PARAMETER_CONTAINER_SIZE, 1000000)

    print('Write a 1000-byte buffer to the container')
    info = RECORDER_BUFFER_INFO()
    data = bytearray(1000)
    info.size = len(data)
    info.pitch = 100
    info.width = 100
    info.height = 10
    info.pixelformat = 0x01080001 # PFNC Mono8
    info.partCount = 1
    recorder.write(info, data)

    show_recorder_parameters(recorder)
    
    print('Trim & close the recorder container')

print('Reopen the recorder for reading')
with recorder_lib.open_recorder(container_path, RECORDER_OPEN_MODE_READ) as recorder:

    show_recorder_parameters(recorder)

    print('Close the recorder container')
