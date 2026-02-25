"""Acquire and convert frames to RGB8 to produce an avi file with opencv and numpy"""

from egrabber import *
import ctypes as ct
import cv2
import numpy as np
import os
import sys

gui = 'nogui' not in sys.argv

def rgb8_to_ndarray(rgb, w, h):
    data = ct.cast(rgb.get_address(), ct.POINTER(ct.c_ubyte * rgb.get_buffer_size())).contents
    c = 3
    return np.frombuffer(data, count=rgb.get_buffer_size(), dtype=np.uint8).reshape((h,w,c))

def loop(grabber, out):
    if not gui:
        countLimit = 10
    count = 0
    grabber.start()
    while True:
        with Buffer(grabber, timeout=1000) as buffer:
            w = buffer.get_info(BUFFER_INFO_WIDTH, INFO_DATATYPE_SIZET)
            h = buffer.get_info(BUFFER_INFO_DELIVERED_IMAGEHEIGHT, INFO_DATATYPE_SIZET)
            rgb = buffer.convert('RGB8')
            img = rgb8_to_ndarray(rgb, w, h)
            out.write(img)
            count += 1
            if gui:
                cv2.imshow("Press any key to exit", img)
                if cv2.waitKey(1) >= 0:
                    break
            elif count == countLimit:
                break

def run(grabber):
    grabber.realloc_buffers(3)
    w = grabber.get_width()
    h = grabber.get_height()
    fourcc = cv2.VideoWriter_fourcc(*'DIVX')
    fps = 20.0
    outdir = '{}/{}.output'.format(os.getenv('OUTPUT_DIR', os.path.dirname(__file__)), os.path.splitext(os.path.basename(__file__))[0])
    if not os.path.isdir(outdir):
        os.makedirs(outdir)
    out = cv2.VideoWriter(os.path.join(outdir, 'output.avi'), fourcc, fps, (w,  h))
    loop(grabber, out)
    if gui:
        cv2.destroyAllWindows()

gentl = EGenTL()
grabber = EGrabber(gentl)
run(grabber)
