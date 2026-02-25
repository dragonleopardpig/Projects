"""Command-line interface using GenApi commands for serial communication with a Camera Link camera"""

import time
from egrabber import *

class SerialCLI:
    def __init__(self, grabber):
        self.device = grabber.device
        self.cli_timeout = 1000
        self.serial_timeout = 0
        self.serial_access_buffer_length = 4096
        self.open() # open Camera Link serial communication

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close() # close Camera Link serial communication

    def run(self):
        self.flush() # clear out any pending bytes in the serial read queue
        self.setup_baudrate()
        self.setup_eol()
        self.device.set('SerialTimeout', self.serial_timeout)
        self.device.set('SerialAccessBufferLength', self.serial_access_buffer_length)
        while True:
            command = ''
            while not command:
                command = input('Enter a command (enter :q to quit): ')
            if command == ':q':
                break
            self.write(command + self.eol) # write bytes to the serial communication port
            self.drain() # wait for any pending bytes in the serial write queue to be written
            while self.is_data_incoming(self.cli_timeout):
                print(self.read_available_data()) # read available bytes from the serial communication port

    def setup_baudrate(self):
        while True:
            baudrates = self.device.enum_entries('SerialBaudRate')
            baudrate = input('Please enter a SerialBaudRate [%s]: ' % '/'.join(baudrates))
            try:
                self.device.set('SerialBaudRate', baudrate)
                break
            except Exception as e:
                print(e)

    def setup_eol(self):
        self.eol = ''
        while not self.eol:
            eol = input('Please enter EOL character used by the remote device [CR/LF/CRLF]: ')
            if eol == 'CR':
                self.eol = '\r'
            elif eol == 'LF':
                self.eol = '\n'
            elif eol == 'CRLF':
                self.eol = '\r\n'
            else:
                print('Invalid entry %s' % eol)

    def is_data_incoming(self, timeout_ms):
        stop = time.time() + timeout_ms / 1000
        while time.time() < stop:
            if self.device.get('SerialReadQueueSize') > 0:
                return True
        return False

    def check_serial_operation_status(self, raiseOnFailure=False):
        status = self.device.get('SerialOperationStatus')
        if status != 'Success':
            operation = self.device.get('SerialOperationSelector')
            message = operation + ' ' + status
            if raiseOnFailure:
                raise Exception(message)
            else:
                print(message)

    def open(self):
        self.device.set('SerialOperationSelector', 'Open')
        self.device.execute('SerialOperationExecute')
        self.check_serial_operation_status(True)

    def close(self):
        self.device.set('SerialOperationSelector', 'Close')
        self.device.execute('SerialOperationExecute')
        self.check_serial_operation_status()

    def read(self, n):
        if n > self.serial_access_buffer_length:
            n = self.serial_access_buffer_length
        self.device.set('SerialOperationSelector', 'Read')
        self.device.set('SerialAccessLength', n)
        self.device.execute('SerialOperationExecute')
        self.check_serial_operation_status()
        readsize = self.device.get('SerialOperationResult')
        data = self.device.get('SerialAccessBuffer', dtype=bytes, size=readsize)
        return data.decode()

    def read_available_data(self):
        return self.read(self.device.get('SerialReadQueueSize'))

    def write(self, command):
        data = command.encode()
        if len(data) > self.serial_access_buffer_length:
            print('Command size can not be greater than SerialAccessBufferLength (%d)' % self.serial_access_buffer_length)
            return
        self.device.set('SerialOperationSelector', 'Write')
        self.device.set('SerialAccessLength', len(data))
        self.device.set('SerialAccessBuffer', data)
        self.device.execute('SerialOperationExecute')
        self.check_serial_operation_status()

    def flush(self):
        self.device.set('SerialOperationSelector', 'Flush')
        self.device.execute('SerialOperationExecute')
        self.check_serial_operation_status()

    def drain(self):
        self.device.set('SerialOperationSelector', 'Drain')
        self.device.execute('SerialOperationExecute')
        self.check_serial_operation_status()

gentl = EGenTL(Grablink())
grabber = EGrabber(gentl)
with SerialCLI(grabber) as cli:
    cli.run()
