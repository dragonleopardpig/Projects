#include "../tools/tools.h"

#include <EGrabber.h>
#include <FormatConverter.h>

using namespace Euresys;

namespace {

class MyEGrabber : public EGrabberCallbackOnDemand {
public:
    MyEGrabber(EGenTL &gentl)
    : EGrabberCallbackOnDemand(gentl)
    , converter(gentl)
    , numImage(0)
    {
        configureLUTControl();
        reallocBuffers(1);
    }
    void configureLUTControl() {
        setString<RemoteModule>("PixelFormat", "Mono8");
        execute<StreamModule>("StreamReset");
        setString<StreamModule>("LUTConfiguration", "M_8x8");
    }
    void disableLutConfig() {
        setString<StreamModule>("LUTEnable", "Off");
        start(1);
        processEvent<NewBufferData>(1000);
    }
    void configLutWithCppFunction() {
        setString<StreamModule>("LUTSet", "Set1");
        setUserLut();
        setString<StreamModule>("LUTEnable", "Set1");
        start(1);
        processEvent<NewBufferData>(1000);
    }
    void configLutWithPredefinedScript() {
        setString<StreamModule>("LUTSet", "Set2");
        runScript("require('egrabber://lut/emphasis')(grabbers[0], { Emphasis: 0.5, Negative: true });");
        setString<StreamModule>("LUTEnable", "Set2");
        start(1);
        processEvent<NewBufferData>(1000);
    }
    void configLutWithUserScript() {
        setString<StreamModule>("LUTSet", "Set3");
        runScript(Tools::getSampleFilePath("250-using-lut.userLUT.js"));
        setString<StreamModule>("LUTEnable", "Set3");
        start(1);
        processEvent<NewBufferData>(1000);
    }
    // user method: invert pixels values Monochrome x-bits to x-bits
    void setUserLut() {
        int64_t lutLength = getInteger<StreamModule>("LUTLength");
        int64_t lutMaxValue = getInteger<StreamModule>("LUTMaxValue");
        for (int64_t lutIndex = 0; lutIndex < lutLength; ++lutIndex) {
            setInteger<StreamModule>("LUTIndex", lutIndex);
            setString<StreamModule>("LUTValue", Tools::toString(lutMaxValue - (lutIndex * (double)lutMaxValue / (lutLength - 1))));
        }
    }
private:
    FormatConverter converter;
    int64_t numImage;
    virtual void onNewBufferEvent(const NewBufferData &data) {
        ScopedBuffer buffer(*this, data);
        FormatConverter::Auto bgr(converter, FormatConverter::OutputFormat("BGR8"), 
            buffer.getInfo<uint8_t *>(gc::BUFFER_INFO_BASE),
            buffer.getInfo<uint64_t>(gc::BUFFER_INFO_PIXELFORMAT),
            buffer.getInfo<size_t>(gc::BUFFER_INFO_WIDTH),
            buffer.getInfo<size_t>(gc::BUFFER_INFO_DELIVERED_IMAGEHEIGHT));
        bgr.saveToDisk(Tools::getEnv("sample-output-path") + "/frame.NNN.jpeg", ++numImage);
    }
};

}
static void sample() {
    EGenTL genTL;
    MyEGrabber grabber(genTL);
    grabber.disableLutConfig();
    grabber.configLutWithCppFunction();
    grabber.configLutWithPredefinedScript();
    grabber.configLutWithUserScript();
    grabber.execute<StreamModule>("StreamReset");
}

static Tools::Sample addSample(__FILE__, sample, "Configure and enable the LUT processor");
