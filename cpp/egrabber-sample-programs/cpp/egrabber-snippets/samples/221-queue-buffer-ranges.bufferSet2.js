function config(grabber) {
    grabber.StreamPort.set('ReverseY', true); // Vertically flipped (bottom-up) image
}

config(grabbers[0]);
