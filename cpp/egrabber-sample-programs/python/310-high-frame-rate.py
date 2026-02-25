"""Grab in high frame rate mode for 10 seconds"""

from egrabber import *
import time

def processImage(ptr, w, h, size):
    # processing code
    pass

gentl = EGenTL()
grabber = EGrabber(gentl)

grabber.stream.set('BufferPartCount', 1)
w = grabber.stream.get('Width')
h = grabber.stream.get('Height')

grabber.stream.set('BufferPartCount', 100)

grabber.realloc_buffers(20)
grabber.start()

t_start = time.time()
t_stop = t_start + 10
t_show_stats = t_start + 1
t = t_start
while t < t_stop:
    with Buffer(grabber) as buffer:
        bufferPtr = buffer.get_info(BUFFER_INFO_BASE, INFO_DATATYPE_PTR)
        imageSize = buffer.get_info(BUFFER_INFO_CUSTOM_PART_SIZE, INFO_DATATYPE_SIZET)
        delivered = buffer.get_info(BUFFER_INFO_CUSTOM_NUM_DELIVERED_PARTS, INFO_DATATYPE_SIZET)
        processed = 0
        while processed < delivered:
            imagePtr = bufferPtr + processed * imageSize
            processImage(imagePtr, w, h, imageSize)
            processed = processed + 1
    if t >= t_show_stats:
        dr = grabber.stream.get('StatisticsDataRate')
        fr = grabber.stream.get('StatisticsFrameRate')
        print('{}x{} : {:.0f} MB/s, {:.0f} fps'.format(w, h, dr, fr))
        t_show_stats = t_show_stats + 1
    t = time.time()
