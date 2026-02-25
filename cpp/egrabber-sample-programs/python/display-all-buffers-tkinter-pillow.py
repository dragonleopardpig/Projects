"""Simple tkinter application showing acquired data processed by a Pillow contour filter"""

from egrabber import *
from PIL import Image, ImageFilter
from ctypes import cast, POINTER, c_ubyte
import threading
import os

gui = 'nogui' not in sys.argv
if gui:
    import tkinter as tk
    from PIL import ImageTk

def acquisition(root, event):
    panel = None
    if root is None:
        countLimit = 10
        outdir = '{}/{}.output'.format(os.getenv('OUTPUT_DIR', os.path.dirname(__file__)), os.path.splitext(os.path.basename(__file__))[0])
        if not os.path.isdir(outdir):
            os.makedirs(outdir)
    count = 0
    try:
        while not event.is_set():
            with Buffer(grabber, timeout=1000) as buffer:
                format = gentl.image_get_pixel_format(buffer.get_info(BUFFER_INFO_PIXELFORMAT, INFO_DATATYPE_UINT64))
                ptr = buffer.get_info(BUFFER_INFO_BASE, INFO_DATATYPE_PTR)
                w = buffer.get_info(BUFFER_INFO_WIDTH, INFO_DATATYPE_SIZET)
                h = buffer.get_info(BUFFER_INFO_DELIVERED_IMAGEHEIGHT, INFO_DATATYPE_SIZET)
                size = buffer.get_info(BUFFER_INFO_DATA_SIZE, INFO_DATATYPE_SIZET)
                fid = buffer.get_info(BUFFER_INFO_FRAMEID, INFO_DATATYPE_UINT64)
                if format == 'Mono8':
                    data = cast(ptr, POINTER(c_ubyte * size)).contents
                    imgFormat = 'L'
                else:
                    rgb = buffer.convert('RGB8')
                    data = cast(rgb.get_address(), POINTER(c_ubyte * rgb.get_buffer_size())).contents
                    imgFormat = 'RGB'
                pimg = Image.frombuffer(imgFormat, (w, h), data, 'raw', imgFormat, 0, 1)
                pimg = pimg.filter(ImageFilter.CONTOUR)
                count += 1
                if root is not None:
                    tkimage = ImageTk.PhotoImage(pimg)
                    if panel is None:
                        panel = tk.Label(root, image=tkimage)
                        panel.pack()
                    else:
                        panel.configure(image=tkimage)
                    panel.image = tkimage
                    root.title('{} {}x{} Frame {}'.format(format, w, h, fid))
                else:
                    pimg.save(os.path.join(outdir, "image-{}-{}x{}-{}.png".format(format, w, h, fid)))
                    if count == countLimit:
                        break
    finally:
        if root is not None:
            root.quit()

def run(grabber):
    grabber.realloc_buffers(3)
    root = tk.Tk() if gui else None
    event = threading.Event()
    live = threading.Thread(target=acquisition, args=(root, event))
    grabber.start()
    live.start()
    if gui:
        root.protocol("WM_DELETE_WINDOW", event.set)
        root.mainloop()

gentl = EGenTL()
grabber = EGrabber(gentl)
run(grabber)
