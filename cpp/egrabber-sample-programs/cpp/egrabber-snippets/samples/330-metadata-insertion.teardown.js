var p = grabbers[0].StreamPort;
for (var selector of p.$ee('GeneralPurposeCounterSelector')) {
    p.set('GeneralPurposeCounterSelector', selector);
    p.set('GeneralPurposeCounterEnable', false);
}
p.set("LineMetadataInsertionEnable", false);
p.set("BufferMetadataInsertionEnable", false);
