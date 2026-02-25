/** enabling filter driver will capture contents before network analyzer may show them
 *  it should not prevent multicast operation, but clearly makes it harder to investigate
 *  in case of interference with the firewall
 */
grabbers[0].StreamPort.set('FilterDriverEnable', 'False');
