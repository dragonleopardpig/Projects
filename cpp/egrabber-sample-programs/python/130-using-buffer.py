"""Simple Grab N with manual buffer management"""

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
    buffer = Buffer(grabber)
    rgb = buffer.convert('RGB8')
    rgb.save_to_disk(outdir + '/frame.{}.jpeg'.format(frame))
    buffer.push()
