// user methode: invert pixels values
function setUserLut(g) {
    var n = g.StreamPort.get('LUTLength');
    var maxValue = g.StreamPort.get('LUTMaxValue');
    var lut = [];
    var i;
    for (i = 0; i < n; ++i) {
        lut.push(Math.floor(maxValue - (i * maxValue / (n - 1))));
    }
    g.StreamPort.set('LUTValue[LUTIndex=0]', lut);
}

setUserLut(grabbers[0]);
 