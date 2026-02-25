"""Grab into user allocated buffer"""

from egrabber import *

gentl = EGenTL()
grabber = EGrabber(gentl)
payload_size = grabber.get_payload_size()
user_buffer = bytearray(payload_size)
grabber.announce_and_queue(UserMemory(user_buffer))
grabber.start(1)
with Buffer(grabber) as buffer:
    base = buffer.get_info(BUFFER_INFO_BASE, INFO_DATATYPE_PTR)
    data_size = buffer.get_info(BUFFER_INFO_DATA_SIZE, INFO_DATATYPE_SIZET)
    print('User memory address: {}, buffer data size: {}'.format(base, data_size))
grabber.stop()
grabber.realloc_buffers(0)
