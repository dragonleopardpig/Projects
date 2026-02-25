"""Queries on GenApi commands"""

from egrabber import *

gentl = EGenTL()
grabber = EGrabber(gentl)

camera_features = grabber.remote.features()

for feature in camera_features:
    is_command = grabber.remote.command(feature)
    if is_command: 
        is_command_done = grabber.remote.done(feature)
        if is_command_done:
            print('The command {} is done.'.format(feature))
        else:
            print('The command {} is not done, it is still executing.'.format(feature))
