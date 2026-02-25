#include <string>
#include <map>
#include <iostream>
#include <fstream>

#if defined(linux) || defined(__linux) || defined(__linux__) || (defined(__APPLE__) && defined(__MACH__))
#ifndef _XOPEN_SOURCE
#define _XOPEN_SOURCE 600
#endif
#include <stdlib.h>
static void openPage(const std::string &link) {
#if defined(__APPLE__) && defined(__MACH__)
    std::string command("open");
#else
    std::string command("xdg-open");
#endif
    command += " " + link;
    system(command.c_str());
}
#else
#include <windows.h>
#include <ShellApi.h>
static void openPage(const std::string &link) {
    ShellExecuteA(GetDesktopWindow(), "open", link.c_str(), NULL, NULL, SW_SHOW);
}
#endif

#include <EGrabber.h>

using namespace Euresys;

namespace {

typedef uint16_t ffc_coeff_t;

// Pack coefficients in the Coaxlink card format
//   [Offset:15..10][Gain:9..0]
//   Gain: UQ2.8 (unsigned Fix-Point with 2 integer bits and 8 fractional bits)
//   Offset: Unsigned integer (6 bits)
ffc_coeff_t packOffsetGain(unsigned int offset, double gain) {
    if (gain < 0) {
        throw std::invalid_argument("Negative gain");
    }
    if (offset > 0x3f) {
        offset = 0x3f;
    }
    ffc_coeff_t coeff = (ffc_coeff_t)(gain * 256);
    if (coeff > 0x3ff) {
        coeff = 0x3ff;
    }
    return (ffc_coeff_t)((offset << 10) | coeff);
}

// Component filter parameters (for ROI specific processing)
// Component at (col, row) is selected if following condition is met:
// (left <= col) && (col < left + width) && (top <= row) && (row < top + height)
class ComponentROI {
    public:
        ComponentROI(size_t left, size_t top, size_t width, size_t height)
        : left(left)
        , top(top)
        , width(width)
        , height(height)
        {}
        bool colPredicate(size_t col) const {
            return !width || ((left <= col) && (col < left + width));
        }
        bool rowPredicate(size_t row) const {
            return !height || ((top <= row) && (row < top + height));
        }
    private:
        size_t left;
        size_t top;
        size_t width;
        size_t height;
};

// Component filter parameters (for component specific processing)
// Component at (col, row) is selected if following condition is met:
// (col % col_divisor == col_remainder) && (row % row_divisor == row_remainder)
class ComponentFilter {
    public:
        ComponentFilter(const std::string &name,
                        size_t col_remainder, size_t col_divisor,
                        size_t row_remainder, size_t row_divisor)
        : name(name)
        , col_remainder(col_remainder)
        , col_divisor(col_divisor)
        , row_remainder(row_remainder)
        , row_divisor(row_divisor)
        {}
        bool colPredicate(size_t col) const {
            return (col % col_divisor == col_remainder);
        }
        bool rowPredicate(size_t row) const {
            return (row % row_divisor == row_remainder);
        }
        const std::string &getComponentName() const {
            return name;
        }
    private:
        std::string name;
        size_t col_remainder;
        size_t col_divisor;
        size_t row_remainder;
        size_t row_divisor;
};

// Structure storing component values of averaged acquired image and
// managing individual components to consider while evaluating coefficients
class Image {
    public:
        Image(const std::string &pixelFormat, size_t width, size_t height,
              size_t bytesPerPixel, size_t bitsPerPixel,
              size_t roi_x, size_t roi_y, size_t roi_width, size_t roi_height,
              bool performBalance)
        : pixelFormat(pixelFormat)
        , width(width)
        , height(height)
        , bytesPerPixel(bytesPerPixel)
        , bitsPerPixel(bitsPerPixel)
        , componentsPerPixel(getComponentsPerPixel(pixelFormat))
        , bytesPerComponent(bytesPerPixel / componentsPerPixel)
        , bitsPerComponent(bitsPerPixel / componentsPerPixel)
        , componentCols(width * componentsPerPixel)
        , componentRows(height)
        , roi(roi_x * componentsPerPixel, roi_y, roi_width * componentsPerPixel, roi_height)
        , performBalance(performBalance)
        , componentFilters(getComponentFilters(pixelFormat))
        , componentValues(componentRows * componentCols)
        {}

        // total number of components in the image
        size_t size() const {
            return componentValues.size();
        }

        // component accessor by index
        unsigned int &operator[](size_t i) {
            return componentValues[i];
        }
        const unsigned int &operator[](size_t i) const {
            return componentValues[i];
        }

        // component accessor by coordinates
        unsigned int &operator()(size_t col, size_t row) {
            return componentValues[row * componentCols + col];
        }
        const unsigned int &operator()(size_t col, size_t row) const {
            return componentValues[row * componentCols + col];
        }

        // number of individual components to consider while evaluating coefficients
        size_t componentsToProcess() const {
            return componentFilters.size();
        }
        const std::string &nameOfComponentToProcess(size_t component) const {
            return componentFilters[component].getComponentName();
        }

        // predicate controlling whether a column component is related to a specific component to process
        bool colPredicate(size_t component, size_t col, bool checkRoi) const {
            if (!checkRoi || roi.colPredicate(col)) {
                return componentFilters[component].colPredicate(col);
            } else {
                return false;
            }
        }
        // predicate controlling whether a row component is related to a specific component to process
        bool rowPredicate(size_t component, size_t row, bool checkRoi) const {
            if (!checkRoi || roi.rowPredicate(row)) {
                return componentFilters[component].rowPredicate(row);
            } else {
                return false;
            }
        }

        const std::string pixelFormat;
        const size_t width;
        const size_t height;
        const size_t bytesPerPixel;
        const size_t bitsPerPixel;
        const size_t componentsPerPixel;
        const size_t bytesPerComponent;
        const size_t bitsPerComponent;
        const size_t componentCols;
        const size_t componentRows;
        const ComponentROI roi;
        const bool performBalance;
    private:
        const std::vector<ComponentFilter> componentFilters;
        std::vector<unsigned int> componentValues;

        static size_t getComponentsPerPixel(const std::string &pixelFormat) {
            if (0 == pixelFormat.find("Mono")) {
                return 1;
            } else if (0 == pixelFormat.find("RGBa")) {
                return 4;
            } else if (0 == pixelFormat.find("RGB")) {
                return 3;
            } else if (0 == pixelFormat.find("BayerBG")) {
                return 1;
            } else if (0 == pixelFormat.find("BayerGB")) {
                return 1;
            } else if (0 == pixelFormat.find("BayerRG")) {
                return 1;
            } else if (0 == pixelFormat.find("BayerGR")) {
                return 1;
            } else {
                throw std::runtime_error("Unsupported pixel format");
            }
        }
        static std::vector<ComponentFilter> getComponentFilters(const std::string &pixelFormat) {
            std::vector<ComponentFilter> componentFilters;
            if (0 == pixelFormat.find("Mono")) {
                // Mono pattern has one component per pixel, all components are
                // processed together while computing averages and the
                // resuling flat field correction coefficients
                //     +- col such that (col % 1 == 0)
                //     |
                //    +-+
                //    |Y| row such that (row % 1 == 0)
                //    +-+
                componentFilters.push_back(ComponentFilter("Luminance", 0, 1, 0, 1));
            } else if (0 == pixelFormat.find("RGBa")) {
                // RGBa pattern is split into 4 components, each component is
                // processed individually while computing averages and the
                // resuling flat field correction coefficients
                //     +------- col such that (col % 4 == 0)
                //     | +----- col such that (col % 4 == 1)
                //     | | +--- col such that (col % 4 == 2)
                //     | | | +- col such that (col % 4 == 3)
                //     | | | |
                //    +-+-+-+-+
                //    |R|G|B|a| row such that (row % 1 == 0)
                //    +-+-+-+-+
                componentFilters.push_back(ComponentFilter("Red",   0, 4, 0, 1));
                componentFilters.push_back(ComponentFilter("Green", 1, 4, 0, 1));
                componentFilters.push_back(ComponentFilter("Blue",  2, 4, 0, 1));
                // The "Alpha" components are excluded, we don't want to correct them
            } else if (0 == pixelFormat.find("RGB")) {
                // RGB pattern is split into 3 components (similar to RGBa)
                componentFilters.push_back(ComponentFilter("Red",   0, 3, 0, 1));
                componentFilters.push_back(ComponentFilter("Green", 1, 3, 0, 1));
                componentFilters.push_back(ComponentFilter("Blue",  2, 3, 0, 1));
            } else if (0 == pixelFormat.find("BayerBG")) {
                // BayerBG pattern is split into 4 artificial components depicted below,
                // these components are processed individually while computing averages
                // and the resuling flat field correction coefficients
                //      +--- col such that (col % 2 == 0)
                //      | +- col such that (col % 2 == 1)
                //      | |
                //     +-+-+
                //     |B|G| row such that (row % 2 == 0)
                //     +-+-+
                //     |G|R| row such that (row % 2 == 1)
                //     +-+-+
                componentFilters.push_back(ComponentFilter("B",    0, 2, 0, 2));
                componentFilters.push_back(ComponentFilter("G(1)", 1, 2, 0, 2));
                componentFilters.push_back(ComponentFilter("G(2)", 0, 2, 1, 2));
                componentFilters.push_back(ComponentFilter("R",    1, 2, 1, 2));
            } else if (0 == pixelFormat.find("BayerGB")) {
                componentFilters.push_back(ComponentFilter("G(1)", 0, 2, 0, 2));
                componentFilters.push_back(ComponentFilter("B",    1, 2, 0, 2));
                componentFilters.push_back(ComponentFilter("R",    0, 2, 1, 2));
                componentFilters.push_back(ComponentFilter("G(2)", 1, 2, 1, 2));
            } else if (0 == pixelFormat.find("BayerRG")) {
                componentFilters.push_back(ComponentFilter("R",    0, 2, 0, 2));
                componentFilters.push_back(ComponentFilter("G(1)", 1, 2, 0, 2));
                componentFilters.push_back(ComponentFilter("G(2)", 0, 2, 1, 2));
                componentFilters.push_back(ComponentFilter("B",    1, 2, 1, 2));
            } else if (0 == pixelFormat.find("BayerGR")) {
                componentFilters.push_back(ComponentFilter("G(1)", 0, 2, 0, 2));
                componentFilters.push_back(ComponentFilter("R",    1, 2, 0, 2));
                componentFilters.push_back(ComponentFilter("B",    0, 2, 1, 2));
                componentFilters.push_back(ComponentFilter("G(2)", 1, 2, 1, 2));
            } else {
                throw std::runtime_error("Unsupported pixel format");
            }
            return componentFilters;
        }
};

void message(const std::string &msg) {
    std::cout << msg << std::endl;
}

void intro() {
    message("Flat Field Correction Wizard");
}

// Class handling command line arguments
class Options {
    private:
        std::map<std::string, std::string> args;
        static const char *helpLines[];
        void checkOptionName(const std::string &name) {
            for (const char **line = helpLines; *line; ++line) {
                std::string str(*line);
                if ((str.find(" " + name + "=") != std::string::npos) ||
                    (str.find(" " + name + " ") != std::string::npos)) {
                    return;
                }
            }
            throw std::runtime_error("Unknown option " + name);
        }
    public:
        Options(int argc, char *argv[]) {
            for (int i = 1; i < argc; ++i) {
                std::string arg(argv[i]);
                std::size_t sep = arg.find('=');
                if (sep != std::string::npos) {
                    std::string name(arg.substr(0, sep));
                    std::string value(arg.substr(sep + 1));
                    checkOptionName(name);
                    args[name] = value;
                } else {
                    checkOptionName(arg);
                    args[arg];
                }
            }
        }
        bool check(const std::string &name) const {
            return args.find(name) != args.end();
        }
        std::string value(const std::string &name, const std::string &def = "") const {
            std::map<std::string, std::string>::const_iterator it = args.find(name);
            if (it == args.end()) {
                return def;
            }
            return it->second;
        }
        int integer(const std::string &name, int def) const {
            std::map<std::string, std::string>::const_iterator it = args.find(name);
            if (it == args.end()) {
                return def;
            }
            std::istringstream ss(it->second);
            int v;
            ss >> v;
            return v;
        }
        void help() {
            intro();
            for (const char **line = helpLines; *line; ++line) {
                message(*line);
            }
        }
};

std::string ensureFileExtension(const std::string &ext, const std::string &filepath) {
    if (filepath.length() < ext.length()) {
        return filepath + ext;
    } else if (filepath.substr(filepath.length() - ext.length()) != ext) {
        return filepath + ext;
    } else {
        return filepath;
    }
}

const char *Options::helpLines[] = {
    "fcc-wizard [OPTIONS]",
    "",
    "Options:",
    "  --if=INT                 Index of GenTL interface to use",
    "  --dev=INT                Index of GenTL device to use",
    "  --ds=INT                 Index of GenTL data stream to use",
    "  --average=INT            Number of images to average (default: 10)",
    "  --roi_x=INT              Horizontal offset in pixels of ROI upper-left corner (default: 0)",
    "  --roi_y=INT              Vertical offset in pixels of ROI upper-left corner (default: 0; ignored for line-scan)",
    "  --roi_width=INT          Width of ROI (default: whole image)",
    "  --roi_height=INT         Height of ROI (default: whole image; ignored for line-scan)",
    "  --balance                Compute flat image average on all components rather than on each component",
    "  --linescan               Force line-scan mode i.e. average image lines (automatically enabled for line-scan cards)",
    "  --dark-setup=SCRIPT      Path to setup script for dark acquisitions",
    "  --flat-setup=SCRIPT      Path to setup script for flat acquisitions",
    "  --timeout=MS             Maximum time in milliseconds to wait for an image (default: 1000)",
    "  --dark-histogram=FILE    Path to histogram html page of average dark image to output and open",
    "  --flat-histogram=FILE    Path to histogram html page of average flat image to output and open",
    "  --output-ffc=FILE        Path to coefficients output file (Coaxlink ffc binary format)",
    "  --load-ffc=FILE          Load coefficients into Coaxlink coefficients partition (default: computed coefficients)",
    "  --no-interact            Skip user interaction",
    "  -h  --help               Display help message",
    "",
    "Note: the ROI options allow defining a rectangular region to consider while computing averages,",
    "      this is useful to eliminate pixels close to borders in images subject to vignetting.",
    0
};

template <typename T> inline void addComponents(Image &image, T *raw) {
    const size_t N = image.size();
    for (size_t i = 0; i < N; ++i) {
        image[i] += raw[i];
    }
}

// Extract all components from the raw image pointed to by ptr into image
void addImage(Image &image, void *ptr) {
    if (image.bytesPerComponent == 1) {
        addComponents(image, (uint8_t *)ptr);
    } else if (image.bytesPerComponent == 2) {
        addComponents(image, (uint16_t *)ptr);
    } else {
        throw std::runtime_error("Unsupported pixel component size");
    }
}

// Divide all component image values
void divImage(Image &image, unsigned int d) {
    const size_t N = image.size();
    for (size_t i = 0; i < N; ++i) {
        image[i] = (image[i] + d / 2) / d;
    }
}

// Compute the average value of a specific component
unsigned int avgImageComponent(const Image &image, size_t component) {
    uint64_t a = 0;
    size_t n = 0;
    for (size_t row = 0; row < image.componentRows; ++row) {
        if (image.rowPredicate(component, row, true)) {
            for (size_t col = 0; col < image.componentCols; ++col) {
                if (image.colPredicate(component, col, true)) {
                    a += image(col, row);
                    ++n;
                }
            }
        }
    }
    if (!n) {
        throw std::runtime_error("No component values");
    }
    return (unsigned int)((a + n / 2) / n);
}

// Compute the balance average value of components
unsigned int avgImageBalance(const Image &image) {
    uint64_t a = 0;
    size_t n = 0;
    for (size_t component = 0; component < image.componentsToProcess(); ++component) {
        a += avgImageComponent(image, component);
        ++n;
    }
    if (!n) {
        throw std::runtime_error("No component values");
    }
    return (unsigned int)((a + n / 2) / n);
}

void averageLines(Image &line, const Image &image) {
    const size_t N = image.size();
    const size_t W = line.size();
    const size_t H = N / W;
    if (W != image.componentCols || H != image.componentRows) {
        throw std::invalid_argument("Invalid image size");
    }
    for (size_t i = 0; i < N; ++i) {
        line[i % W] += image[i];
    }
    divImage(line, (unsigned int)H);
}

// Compute the histogram of a specific component
std::vector<unsigned int> histogramOfComponent(const Image &image, size_t component) {
    const unsigned int N = 1ULL << image.bitsPerComponent;
    std::vector<unsigned int> histogram(N);
    for (size_t row = 0; row < image.componentRows; ++row) {
        if (image.rowPredicate(component, row, true)) {
            for (size_t col = 0; col < image.componentCols; ++col) {
                if (image.colPredicate(component, col, true)) {
                    unsigned int value = image(col, row);
                    if (value < N) {
                        histogram[value]++;
                    } else {
                        throw std::runtime_error("Component value out of bounds");
                    }
                }
            }
        }
    }
    return histogram;
}

// Replace the first occurence of a substring (from) in a string (input) by another substring (to)
std::string replace(const std::string &input, const std::string &from, const std::string &to) {
    std::size_t pos = input.find(from);
    if (pos == std::string::npos) {
        return input;
    } else {
        return std::string(input).replace(pos, from.length(), to);
    }
}

// Render data as an html page using google scatter chart
void renderData(const std::vector<unsigned int> &data, const std::string &title, const std::string &filepath) {
    // https://developers.google.com/chart/interactive/docs/gallery/scatterchart
    static const char *htmlTemplate[] = {
        "<html>",
            "<head>",
                "<script type='text/javascript' src='https://www.gstatic.com/charts/loader.js'></script>",
                "<script type='text/javascript'>",
                    "google.charts.load('current', {'packages':['corechart']});",
                    "google.charts.setOnLoadCallback(drawChart);",
                    "function drawChart() {",
                        "var data = google.visualization.arrayToDataTable([",
                            "['Value', 'Count'],",
                            "[%%POINTS%%],",
                        "]);",
                        "var options = {",
                            "title: '%%TITLE%%',",
                            "pointSize: 4,",
                            "hAxis: {",
                                "minValue: 0,",
                                "format: {format: '0'},",
                                "ticks: [%%HAXIS.TICKS%%]",
                            "},",
                            "vAxis: {",
                                "minValue: 0,",
                                "format: {format: '0'}",
                            "},",
                            "explorer: {",
                                "keepInBounds: true",
                            "},",
                            "colors: ['red']",
                        "};",
                        "var chart = new google.visualization.ScatterChart(document.getElementById('chart'));",
                        "chart.draw(data, options);",
                    "}",
                "</script>",
            "</head>",
            "<body>",
                "<div id='chart' style='width: 1000px; height: 1000px'></div>",
            "</body>",
        "</html>",
        0
    };
    unsigned int N = (unsigned int)data.size();
    unsigned int x_min = 0;
    unsigned int x_max = 0;
    for (unsigned int i = 0; i < N; ++i) {
        if (data[i]) {
            if (x_max < i) {
                x_max = i;
            }
        }
    }
    std::ofstream output(filepath.c_str(), std::ofstream::binary);
    for (const char **line = htmlTemplate; *line; ++line) {
        std::string htmlLine(*line);
        if (htmlLine.find("%%TITLE%%") != std::string::npos) {
            output << replace(htmlLine, "%%TITLE%%", title) << std::endl;
        } else if (htmlLine.find("%%HAXIS.TICKS%%") != std::string::npos) {
            std::stringstream ss;
            ss << x_min << "," << x_max;
            output << replace(htmlLine, "%%HAXIS.TICKS%%", ss.str()) << std::endl;
        } else if (htmlLine.find("%%POINTS%%") != std::string::npos) {
            for (unsigned int i = 0; i < N; ++i) {
                unsigned int n = data[i];
                if (n) {
                    std::stringstream ss;
                    ss << i << "," << n;
                    output << replace(htmlLine, "%%POINTS%%", ss.str()) << std::endl;
                }
            }
        } else {
            output << htmlLine << std::endl;
        }
    }
}

// Compute the flat field correction gain for each component from dark and flat images
// Ignored components will have the default gain value (1.0)
std::vector<double> computeGain(const Image &dark, const Image &flat) {
    static const double defaultGain = 1.0;
    std::vector<double> gain(dark.size(), defaultGain);
    double flatBalance = (flat.performBalance) ? avgImageBalance(flat) : 0;
    for (size_t component = 0; component < dark.componentsToProcess(); ++component) {
        double averageFlat = (flat.performBalance)
                           ? flatBalance
                           : avgImageComponent(flat, component);
        double averageDark = avgImageComponent(dark, component);
        double m = averageFlat - averageDark;
        for (size_t row = 0; row < dark.componentRows; ++row) {
            if (dark.rowPredicate(component, row, false)) {
                for (size_t col = 0; col < dark.componentCols; ++col) {
                    if (dark.colPredicate(component, col, false)) {
                        unsigned int d = flat(col, row) - dark(col, row);
                        gain[row * dark.componentCols + col] = (d) ? (m / d) : 1.0;
                    }
                }
            }
        }
    }
    return gain;
}

// Compute the flat field correction offset for each component from dark image
// Ignored components will have the default offset value (0)
std::vector<unsigned int> computeOffset(const Image &dark) {
    static const unsigned int defaultOffset = 0;
    std::vector<unsigned int> offset(dark.size(), defaultOffset);
    for (size_t component = 0; component < dark.componentsToProcess(); ++component) {
        for (size_t row = 0; row < dark.componentRows; ++row) {
            if (dark.rowPredicate(component, row, false)) {
                for (size_t col = 0; col < dark.componentCols; ++col) {
                    if (dark.colPredicate(component, col, false)) {
                        offset[row * dark.componentCols + col] = dark(col, row);
                    }
                }
            }
        }
    }
    return offset;
}

// Pack the flat field correction coefficients in binary format for Coaxlink card
std::vector<ffc_coeff_t> packCoefficients(const std::vector<unsigned int> &offset, const std::vector<double> &gain) {
    const size_t N = offset.size();
    std::vector<ffc_coeff_t> coefficients(N);
    for (size_t i = 0; i < N; ++i) {
        coefficients[i] = packOffsetGain(offset[i], gain[i]);
    }
    return coefficients;
}

// Save the flat field correction coefficients to binary file
void savePackedCoefficients(const std::vector<ffc_coeff_t> &coefficients, const std::string &filepath) {
    std::ofstream output(filepath.c_str(), std::ios::binary);
    output.write((char *)&coefficients[0], coefficients.size() * sizeof(ffc_coeff_t));
}

// Load the flat field correction coefficients from binary file
std::vector<ffc_coeff_t> loadPackedCoefficients(const std::string &filepath) {
    std::ifstream input(filepath.c_str(), std::ios::binary);
    input.seekg(0, input.end);
    size_t length = input.tellg();
    input.seekg(0, input.beg);
    std::vector<ffc_coeff_t> coefficients(length / sizeof(ffc_coeff_t));
    input.read((char *)&coefficients[0], coefficients.size() * sizeof(ffc_coeff_t));
    return coefficients;
}

// Acquire several images and return the average image
Image acquireImages(EGenTL &genTL, int interfaceIndex, int deviceIndex, int dataStreamIndex,
                    const std::string &title,
                    int imageCount, int timeout,
                    const std::string &script,
                    const std::string &histogramFilepath, bool openHistogram,
                    size_t roi_x, size_t roi_y, size_t roi_width, size_t roi_height,
                    bool performBalance,
                    bool linescan) {
    EGrabber<CallbackOnDemand> grabber(genTL, interfaceIndex, deviceIndex, dataStreamIndex);
    std::string iid(grabber.getString<InterfaceModule>("InterfaceID"));
    if (!linescan) {
        linescan = std::string::npos != iid.find("line-scan");
    }
    if (!script.empty()) {
        grabber.runScript(script);
    }
    if (grabber.getInteger<StreamModule>(query::available("FfcControl"))) {
        // Make sure the flat field correction is disabled or bypassed
        if (grabber.getString<StreamModule>("FfcControl") == "Enable") {
            grabber.setString<StreamModule>("FfcBypass", "Enable");
        }
    }
    if (grabber.getString<StreamModule>("UnpackingMode") != "Lsb") {
        throw std::runtime_error("Unsupported data stream configuration (feature UnpackingMode)");
    }
    if (grabber.getInteger<StreamModule>("RedBlueSwap")) {
        throw std::runtime_error("Unsupported data stream configuration (feature RedBlueSwap)");
    }
    if (grabber.getInteger<StreamModule>(query::available("BayerMethod")) &&
        grabber.getString<StreamModule>("BayerMethod") != "Disable") {
        throw std::runtime_error("Unsupported data stream configuration (feature BayerMethod)");
    }
    Image image(grabber.getPixelFormat(), grabber.getWidth(), grabber.getHeight(),
                genTL.imageGetBytesPerPixel(grabber.getPixelFormat()),
                genTL.imageGetBitsPerPixel(grabber.getPixelFormat()),
                roi_x, roi_y, roi_width, roi_height, performBalance);
    {
        std::stringstream ss;
        ss << image.pixelFormat
           << " "
           << (int)image.width << "x" << (int)image.height
           << ", "
           << (int)image.componentsPerPixel << ((image.componentsPerPixel <= 1) ? " component" : " components")
           << " per pixel, "
           << (int)image.bytesPerComponent << ((image.bytesPerComponent <= 1) ? " byte" : " bytes")
           << " per component";
        message(ss.str());
        ss.str(std::string()); // clear ss
        ss << "Components processed individually: ";
        for (size_t component = 0; component < image.componentsToProcess(); ++component) {
            ss << image.nameOfComponentToProcess(component);
            if (component + 1 < image.componentsToProcess()) {
                ss << ", ";
            }
        }
        message(ss.str());
    }
    grabber.reallocBuffers(3);
    message("Acquiring images ...");
    grabber.start(imageCount);
    for (int i = 0; i < imageCount; ++i) {
        ScopedBuffer buffer(grabber, timeout);
        void *ptr = buffer.getInfo<void *>(gc::BUFFER_INFO_BASE);
        addImage(image, ptr);
    }
    grabber.stop();
    divImage(image, imageCount); // averaged image
    if (!histogramFilepath.empty()) {
        for (size_t component = 0; component < image.componentsToProcess(); ++component) {
            std::vector<unsigned int> componentHistogram(histogramOfComponent(image, component));
            std::string chartTitle(title + " (" + image.nameOfComponentToProcess(component) + ")");
            std::string ext("." + image.nameOfComponentToProcess(component) + ".html");
            std::string filepath(replace(ensureFileExtension(".html", histogramFilepath), ".html", ext));
            renderData(componentHistogram, chartTitle, filepath);
            if (openHistogram) {
                openPage(filepath);
            }
        }
    }
    if (linescan) {
        message("Averaging lines ... (line-scan mode)");
        // roi_y, roi_height do not make sense in line-scan
        Image line(grabber.getPixelFormat(), grabber.getWidth(), 1,
                   genTL.imageGetBytesPerPixel(grabber.getPixelFormat()),
                   genTL.imageGetBitsPerPixel(grabber.getPixelFormat()),
                   roi_x, 0, roi_width, 0, performBalance);
        averageLines(line, image);
        return line;
    } else {
        return image;
    }
}

// Enable flat field correction and load coefficients into Coaxlink card
void loadCoefficients(EGenTL &genTL, int interfaceIndex, int deviceIndex, int dataStreamIndex,
                      const std::vector<ffc_coeff_t> &coefficients) {
    EGrabber<CallbackOnDemand> grabber(genTL, interfaceIndex, deviceIndex, dataStreamIndex);
    if (!grabber.getInteger<StreamModule>(query::available("FfcControl"))) {
        throw std::runtime_error("Ffc is not available on this grabber");
    }
    // Enable flat field correction if required
    if (grabber.getString<StreamModule>("FfcControl") != "Enable") {
        grabber.setString<StreamModule>("FfcControl", "Enable");
    }
    // And disable flat field correction bypass
    grabber.setString<StreamModule>("FfcBypass", "Disable");
    uint64_t ffcCoefficientBase = grabber.getInteger<StreamModule>("FfcCoefficientPartitionBase");
    uint64_t ffcCoefficientSize = grabber.getInteger<StreamModule>("FfcCoefficientPartitionSize");
    if (ffcCoefficientSize < coefficients.size() * sizeof(ffc_coeff_t)) {
        throw std::runtime_error("Not enough space in the grabber to store flat field correction coefficients for the current image size");
    }
    grabber.gcWritePortData<StreamModule>(ffcCoefficientBase, &coefficients[0], coefficients.size() * sizeof(ffc_coeff_t));
}

void ffcWizard(const Options &options) {
    intro();
    EGenTL genTL;
    int interfaceIndex = options.integer("--if", 0);
    int deviceIndex = options.integer("--dev", 0);
    int dataStreamIndex = options.integer("--ds", 0);
    int imageCount = options.integer("--average", 10);
    int timeout = options.integer("--timeout", 1000);
    bool interact = !options.check("--no-interact");
    int roi_x      = options.integer("--roi_x", 0);
    int roi_y      = options.integer("--roi_y", 0);
    int roi_width  = options.integer("--roi_width", 0);
    int roi_height = options.integer("--roi_height", 0);
    bool balance = options.check("--balance");
    bool linescan = options.check("--linescan");

    bool openHistogram = interact;

    if (!options.value("--load-ffc").empty()) {
        // Load coefficients from file
        std::string filepath(options.value("--load-ffc"));
        message("Reading " + filepath + " ...");
        std::vector<ffc_coeff_t> coefficients(loadPackedCoefficients(filepath));
        message("Loading coefficients into Coaxlink coefficients partition ...");
        loadCoefficients(genTL, interfaceIndex, deviceIndex, dataStreamIndex, coefficients);
    } else {
        // Compute coefficients from dark and flat acquisitions
        if (interact) {
            message("Please setup the camera for dark acquisitions (e.g. using the lens cap) and press Enter to continue.");
            message("Note: the dark component values will be considered as dark current and will be used for dark frame subtraction");
            // Dark current: https://en.wikipedia.org/wiki/Dark_current_(physics)
            // Dark frame subtraction: https://en.wikipedia.org/wiki/Dark-frame_subtraction
            getchar();
        }
        Image dark(acquireImages(genTL, interfaceIndex, deviceIndex, dataStreamIndex,
                                 "Dark Image", imageCount, timeout,
                                 options.value("--dark-setup"),
                                 options.value("--dark-histogram"), openHistogram,
                                 roi_x, roi_y, roi_width, roi_height,
                                 false, linescan));
        if (interact) {
            message("Please setup the camera for flat acquisitions and press Enter to continue.");
            getchar();
        }
        Image flat(acquireImages(genTL, interfaceIndex, deviceIndex, dataStreamIndex,
                                 "Flat Image", imageCount, timeout,
                                 options.value("--flat-setup"),
                                 options.value("--flat-histogram"), openHistogram,
                                 roi_x, roi_y, roi_width, roi_height,
                                 balance, linescan));
        if ((dark.size() != flat.size()) ||
            (dark.componentsPerPixel != flat.componentsPerPixel)) {
            throw std::runtime_error("Dark and flat image configurations do not match");
        }
        message("Computing coefficients ...");
        std::vector<double> gain(computeGain(dark, flat));
        std::vector<unsigned int> offset(computeOffset(dark));
        message("Packing coefficients ...");
        std::vector<ffc_coeff_t> coefficients(packCoefficients(offset, gain));
        if (options.check("--output-ffc")) {
            std::string filepath(ensureFileExtension(".ffc", options.value("--output-ffc")));
            message("Writing " + filepath + " ...");
            savePackedCoefficients(coefficients, filepath);
        }
        if (options.check("--load-ffc")) {
            message("Loading coefficients into Coaxlink coefficients partition ...");
            loadCoefficients(genTL, interfaceIndex, deviceIndex, dataStreamIndex, coefficients);
        }
    }
    message("Done.");
}

}

int main(int argc, char *argv[]) {
    try {
        Options options(argc, argv);
        if (options.check("-h") || options.check("--help")) {
            options.help();
        } else {
            ffcWizard(options);
        }
        return 0;
    } catch (const std::exception &e) {
        std::cerr << e.what() << std::endl;
        return 1;
    } catch (...) {
        std::cerr << "unknown error!" << std::endl;
        return 1;
    }
}
