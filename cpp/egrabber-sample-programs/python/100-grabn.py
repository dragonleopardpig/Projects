"""Simple Grab N using 'with Buffer'"""

import os
outdir = '{}/{}.output'.format(os.getenv('OUTPUT_DIR', os.path.dirname(__file__)), os.path.splitext(os.path.basename(__file__))[0])
if not os.path.isdir(outdir):
    os.makedirs(outdir)

from egrabber import *

gentl = EGenTL()
grabber = EGrabber(gentl)

N = 5
grabber.realloc_buffers(N)

grabber.start(N)
for frame in range(N):
    with Buffer(grabber, timeout=1000) as buffer:
        # Note: the buffer will be pushed back to the input queue automatically
        # when execution of the with-block is finished
        rgb = buffer.convert('RGB8')
        rgb.save_to_disk(outdir + '/frame.{}.jpeg'.format(frame))
