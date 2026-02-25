"""Python version of the C++ 120-converter eGrabber sample program"""

from egrabber import *
import time

gentl = EGenTL()
grabber = EGrabber(gentl)

N = 1
grabber.realloc_buffers(N)
grabber.start(N)
with Buffer(grabber) as buffer:
    count = 1000
    t0 = time.time()
    for i in range(count):
        rgb = buffer.convert('RGB8')
    t1 = time.time()
    dt = t1 - t0
    print('Converted {} {}x{} {} buffers to RGB8 in {:.3f}s, {:.2f}us/buffer, {:.2f}fps'.format(
        count,
        buffer.get_info(BUFFER_INFO_WIDTH, INFO_DATATYPE_SIZET),
        buffer.get_info(BUFFER_INFO_HEIGHT, INFO_DATATYPE_SIZET),
        gentl.image_get_pixel_format(buffer.get_info(BUFFER_INFO_PIXELFORMAT, INFO_DATATYPE_UINT64)),
        dt,
        dt*pow(10,6)/count,
        count/dt
        )
    )
