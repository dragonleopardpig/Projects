"""Export images from the container created by sample260.py to an MKV file, and then use opencv to read the MKV file and display the images"""

import os
import sys
import cv2
from egrabber import *
from egrabber.recorder import *

sys.path.append(os.path.dirname(os.path.abspath(__file__)))
import importlib
sample260 = importlib.import_module('260-recorder-read-write')

gui = 'nogui' not in sys.argv

PFNC_RGB8  = 0x02180014
PFNC_Mono8 = 0x01080001

def export_container(recorder_lib, container_path, output):
    recorder = recorder_lib.open_recorder(container_path, RECORDER_OPEN_MODE_READ)
    recorder.set(RECORDER_PARAMETER_RECORD_INDEX, 0) # index of first record to export
    count = recorder.get(RECORDER_PARAMETER_RECORD_COUNT)
    recorder.export(output, count, export_pixel_format=PFNC_RGB8)

def get_output_dir():
    output_dir = '{}/{}.output'.format(os.getenv('OUTPUT_DIR', os.path.dirname(__file__)), os.path.splitext(os.path.basename(__file__))[0])
    if not os.path.isdir(output_dir):
        os.makedirs(output_dir)
    return output_dir

def get_output_file():
    return os.path.join(get_output_dir(), 'export.mkv')

def get_container_path():
    return get_output_dir()

def read_mkv(mkv_file):
    mkv = cv2.VideoCapture(mkv_file)
    i = 0
    while True:
        ret, img = mkv.read()
        if not ret:
            break
        if gui:
            cv2.imshow('Press any key to go to next image', img)
            while True:
                if cv2.waitKey(1) >= 0:
                    break
        else:
            print('Image %i: ' % i, img.shape, img.dtype)
        i += 1
    if gui:
        cv2.destroyAllWindows()
    mkv.release()

gentl = EGenTL()
recorder_lib = RecorderLibrary()
container_path = get_container_path()
sample260.write_recorder(gentl, recorder_lib, container_path)
mkv_file = get_output_file()
export_container(recorder_lib, container_path, mkv_file)
read_mkv(mkv_file)
