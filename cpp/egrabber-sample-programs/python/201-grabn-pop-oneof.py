"""Grab N frames and get DataStream events with pop_one_of"""

from egrabber import *

gentl = EGenTL()
grabber = EGrabber(gentl)
grabber.enable_event(DataStreamData)

N = 5
grabber.realloc_buffers(N)

def on_new_buffer_event(grabber, data):
    with Buffer(grabber, new_buffer_data=data) as buffer:
        print('NewBufferEvent: {}x{} timestamp={}'.format(
            buffer.get_info(BUFFER_INFO_WIDTH, INFO_DATATYPE_SIZET),
            buffer.get_info(BUFFER_INFO_HEIGHT, INFO_DATATYPE_SIZET),
            data.timestamp))

def on_data_stream_event(grabber, data):
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

grabber.stream.set('EventNotificationAll', 1)
grabber.start(N);

for i in range(3*N):
    try:
        (eventData, eventRest) = grabber.pop_one_of([DataStreamData, NewBufferData], timeout=1000)
        if type(eventData) == NewBufferData:
            on_new_buffer_event(grabber, eventData)
        elif type(eventData) == DataStreamData:
            on_data_stream_event(grabber, eventData)
        print('Pending events: {}'.format(eventRest))
    except Exception as e:
        print(e)
        break

grabber.stream.set('EventNotificationAll', 0)
grabber.disable_event(DataStreamData)
