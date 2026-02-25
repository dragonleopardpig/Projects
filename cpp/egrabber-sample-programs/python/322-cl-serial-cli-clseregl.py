"""Command-line interface using the `clseregl` library for serial communication with a Camera Link camera"""

import sys
import threading
import time
from egrabber.clserial import clseregl as cl

SUPPORTED_BAUDRATES = {
    9600: cl.CL_BAUDRATE_9600,
    19200: cl.CL_BAUDRATE_19200,
    38400: cl.CL_BAUDRATE_38400,
    57600: cl.CL_BAUDRATE_57600,
    115200: cl.CL_BAUDRATE_115200,
    230400: cl.CL_BAUDRATE_230400,
    460800: cl.CL_BAUDRATE_460800,
    921600: cl.CL_BAUDRATE_921600,
}

class ReadDataThread(threading.Thread):
    def __init__(self, serial_ref, interrupt_event):
        super(ReadDataThread, self).__init__()
        self.serial_ref = serial_ref
        self.interrupt_event = interrupt_event
    def run(self):
        while not self.interrupt_event.is_set():
            try:
                read_size = cl.GetNumBytesAvail(self.serial_ref)
                if read_size > 0:
                    read_buffer = cl.SerialRead(self.serial_ref, read_size, 1000)
                    sys.stdout.write(read_buffer)
                    sys.stdout.flush()
                time.sleep(0.02)
            except cl.ClSerialError as error:
                self.interrupt_event.set()
                sys.stdout.write('\n%s' % error)
                sys.stdout.flush()

def main():
    num_ports = cl.GetNumSerialPorts()
    if num_ports == 0:
        print('Sorry, no serial port detected.')
        print('Check if a Grablink is present in your system and if the drivers are correctly loaded...')
        sys.exit(-1)
    print('Detected ports:')
    for i in range(num_ports):
        port_name = cl.GetSerialPortIdentifier(i)
        print(' - Serial Index %d: %s' % (i, port_name))

    port_id = num_ports
    while True:
        try:
            port_id = int(input('\nPlease, select a port in the list above by entering its serial index...\n> '))
        except ValueError:
            print('This is not a valid serial index.')
        else:
            if port_id in range(num_ports):
                break
            print('This serial index is out of range.')
    print('Port selected: %d' % port_id)

    serial_ref = cl.SerialInit(port_id)

    interrupt_event = threading.Event()
    read_data_thread = ReadDataThread(serial_ref, interrupt_event)

    try:
        supported_baudrates = cl.GetSupportedBaudRates(serial_ref)
        print('Enter a baudrate, supported baudrates are:')
        for supported_baudrate, supported_baudrate_id in SUPPORTED_BAUDRATES.items():
            if supported_baudrates & supported_baudrate_id:
                print('  - %s Bauds' % supported_baudrate)

        while True:
            try:
                baudrate = int(input('\nPlease, select a baudrate in the list above by entering its numeric value...\n> '))
            except ValueError:
                print('This is not a valid baudrate.')
            else:
                baudrate_id = SUPPORTED_BAUDRATES.get(baudrate, 0)
                if supported_baudrates & baudrate_id:
                    break
                print('This baudrate is not supported.')
        print('Baudrate selected: %s (baudrate_id=%d)' % (baudrate, baudrate_id))

        cl.SetBaudRate(serial_ref, baudrate_id)

        eol = None
        while eol is None:
            eol = input('Please enter EOL character used by the camera [CR/LF/CRLF/<Nothing>]: ')
            if eol == 'CR':
                eol = '\r'
            elif eol == 'LF':
                eol = '\n'
            elif eol == 'CRLF':
                eol = '\r\n'
            elif eol == '':
                pass
            else:
                print('Invalid EOL character.')
                eol = None

        command = input('Type your commands (or CTRL-C to exit)\n> ')

        read_data_thread.start()
        while read_data_thread.is_alive():
            cl.SerialWrite(serial_ref, command + eol, 1000)
            time.sleep(0.2)
            command = input('\n> ')
    except KeyboardInterrupt:
        interrupt_event.set()
        sys.exit(0)
    except Exception as error:
        interrupt_event.set()
        print('\n%s' % error)
        sys.exit(-1)
    finally:
        print('\nExiting...')
        if read_data_thread.is_alive():
            read_data_thread.join()
        cl.SerialClose(serial_ref)

if __name__ == '__main__':
    main()
