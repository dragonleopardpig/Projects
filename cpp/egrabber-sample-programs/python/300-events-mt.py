"""Grab frames for a few seconds and get DataStream events with callbacks, processing them in a separate thread"""

import threading
import time
from egrabber import *

def on_new_buffer_event(grabber, data, context):
    with Buffer(grabber, new_buffer_data=data) as buffer:
        print('NewBufferEvent: {}x{} timestamp={}'.format(
            buffer.get_info(BUFFER_INFO_WIDTH, INFO_DATATYPE_SIZET),
            buffer.get_info(BUFFER_INFO_HEIGHT, INFO_DATATYPE_SIZET),
            data.timestamp))

def on_data_stream_event(grabber, data, context):
    events = { EVENT_DATA_NUMID_DATASTREAM_START_OF_CAMERA_READOUT: 'StartOfCameraReadout'
             , EVENT_DATA_NUMID_DATASTREAM_END_OF_CAMERA_READOUT: 'EndOfCameraReadout'
             , EVENT_DATA_NUMID_DATASTREAM_START_OF_SCAN: 'StartOfScan'
             , EVENT_DATA_NUMID_DATASTREAM_END_OF_SCAN: 'EndOfScan'
             , EVENT_DATA_NUMID_DATASTREAM_REJECTED_FRAME: 'RejectedFrame'
             , EVENT_DATA_NUMID_DATASTREAM_REJECTED_SCAN: 'RejectedScan'
             , EVENT_DATA_NUMID_DATASTREAM_TRIGGER_TO_CAMERA_READOUT_TIMEOUT: 'TriggerToCameraReadoutTimeout'
             , EVENT_DATA_NUMID_DATASTREAM_CAMERA_READOUT_TIMEOUT: 'CameraReadoutTimeout'
             , EVENT_DATA_NUMID_DATASTREAM_BROKEN_FRAME: 'BrokenFrame'
             , EVENT_DATA_NUMID_DATASTREAM_REJECTED_LINE: 'RejectedLine'
             }
    print('DataStreamEvent: {}'.format(events.get(data.numid, data.numid)))


def process_events(grabber, stop_event):
    while not stop_event.is_set():
        try:
            eventRest = grabber.process_event([DataStreamData, NewBufferData], timeout=1000)
            print(f'Pending events: {eventRest}')
        except Exception as e:
            print(e)


gentl = EGenTL()
grabber = EGrabber(gentl)

grabber.enable_event(DataStreamData)
grabber.stream.set('EventNotificationAll', 1)

grabber.realloc_buffers(5)

grabber.on_new_buffer_event = on_new_buffer_event
grabber.on_data_stream_event = on_data_stream_event

# create a thread to monitor events until stop_event is set
stop_event = threading.Event()
process_events_thread = threading.Thread(target=process_events, args=(grabber, stop_event))

grabber.start()

# start events monitoring thread
process_events_thread.start()

# acquire images for some seconds
time.sleep(3)

# stop the events monitoring thread
stop_event.set()
process_events_thread.join()

grabber.stop()

grabber.stream.set('EventNotificationAll', 0)
grabber.disable_event(DataStreamData)
