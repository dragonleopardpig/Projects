"""Image acquisition and display. When the acquisition is faster than the display processing, buffers are discarded"""

from egrabber import *
from ctypes import cast, POINTER, c_ubyte
import cv2
import numpy as np
import threading

display_zoom = 0.5
latest_buffer = None
total_buffers_count = 0
discarded_buffers_count = 0
condition_variable = threading.Condition()

def process_events(grabber, stop_event):
    while not stop_event.is_set():
        try:
            pending_events_count = grabber.process_event([NewBufferData], timeout=1000)
        except Exception as e:
            print(e)

def on_new_buffer_event(grabber, data, context):
    global latest_buffer
    global total_buffers_count
    global discarded_buffers_count
    total_buffers_count += 1
    buffer = Buffer(grabber, new_buffer_data=data)
    with condition_variable:
        if latest_buffer is not None:
            # latest buffer was not yet displayed => discard
            latest_buffer.push()
            discarded_buffers_count += 1
        latest_buffer = buffer
        condition_variable.notify()

gentl = EGenTL()
grabber = EGrabber(gentl)
grabber.stream.set('EventNotificationAll', 1)

grabber.realloc_buffers(3)
grabber.on_new_buffer_event = on_new_buffer_event

stop_event = threading.Event()
process_events_thread = threading.Thread(target=process_events, args=(grabber, stop_event))

grabber.start()
process_events_thread.start()

while True:
    got_buffer = False
    with condition_variable:
        got_buffer = condition_variable.wait_for(lambda: latest_buffer is not None, timeout=0.1)
        if got_buffer:
            buffer_to_display = latest_buffer
            latest_buffer = None
    if got_buffer:
        ptr = buffer_to_display.get_info(BUFFER_INFO_BASE, INFO_DATATYPE_PTR)
        w = buffer_to_display.get_info(BUFFER_INFO_WIDTH, INFO_DATATYPE_SIZET)
        h = buffer_to_display.get_info(BUFFER_INFO_DELIVERED_IMAGEHEIGHT, INFO_DATATYPE_SIZET)
        bgr = buffer_to_display.convert('BGR8')
        data = cast(bgr.get_address(), POINTER(c_ubyte * bgr.get_buffer_size())).contents
        img = np.frombuffer(data, count=bgr.get_buffer_size(), dtype=np.uint8).reshape((h, w, 3))
        img = cv2.resize(img, (int(w * display_zoom), int(h * display_zoom)))
        cv2.imshow("Press any key to exit", img)
        buffer_to_display.push()
    if cv2.waitKey(1) >= 0:
        break
cv2.destroyAllWindows()

stop_event.set()
process_events_thread.join()

grabber.stop()

grabber.stream.set('EventNotificationAll', 0)

print(f'Total buffers: {total_buffers_count}')
print(f'Discarded buffers: {discarded_buffers_count}')
