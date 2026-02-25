var grabber = grabbers[0];
if (grabber.StreamPort === undefined) {
    /** perpare for opening the StreamPort with multicast destination */
    memento.debug("current destination: " +
                  grabber.DevicePort.get('DestinationAddress') + ":" +
                  grabber.DevicePort.get('DestinationPort'));
    grabber.DevicePort.set('DestinationAddress', '224.0.2.1');
    grabber.DevicePort.set('DestinationPort', 54321);

    memento.info("updated destination: " +
                 grabber.DevicePort.get('DestinationAddress') + ":" +
                 grabber.DevicePort.get('DestinationPort'));
} else {
    /** enabling filter driver will capture contents before network analyzer may show them
     *  it should not prevent multicast operation, but clearly makes it harder to investigate
     *  in case of interference with the firewall
     */
    grabber.StreamPort.set('FilterDriverEnable', 'False');
}
