#include "../tools/tools.h"

#include <EGrabber.h>

using namespace Euresys;

class MySerialCLIGrabber: public EGrabber<CallbackOnDemand> {
    public:
        MySerialCLIGrabber(EGenTL &gentl)
        : EGrabber<CallbackOnDemand>(gentl)
        , cliTimeout(1000)
        , serialTimeout(0)
        , serialAccessBufferLength(4096)
        {
            open(); // open Camera Link serial communication
            flush(); // clear out any pending bytes in the serial read queue
        }

        ~MySerialCLIGrabber() {
            close(); // close Camera Link serial communication
        }

        void startCLI() {
            setup(); // setup SerialAccessControl features
            std::string input;
            while (isStillRunning(input)) {
                write(input + endOfLine); // write bytes to the serial communication port
                drain(); // wait for any pending bytes in the serial write queue to be written
                while (isDataIncoming(cliTimeout)) {
                    std::cout << readAvailableData(); // read available bytes from the serial communication port
                }
            }
        }

    private:
        uint32_t cliTimeout;
        uint32_t serialTimeout;
        uint32_t serialAccessBufferLength;
        std::string serialBaudRate;
        std::string endOfLine;

        void setupBaudRate() {
            typedef std::vector<std::string>::const_iterator it_t;
            std::string input;
            while (serialBaudRate.empty()) {
                std::vector<std::string> eeSerialBaudRate = getStringList<DeviceModule>(query::enumEntries("SerialBaudRate"));
                std::string eeSerialBaudRateStr;
                for (it_t it = eeSerialBaudRate.begin(); it != eeSerialBaudRate.end(); it++) {
                    eeSerialBaudRateStr += (*it + "/");
                }
                Tools::log("Please setup SerialBaudRate (" + eeSerialBaudRateStr + "):");
                std::getline(std::cin, input);
                try {
                    setString<DeviceModule>("SerialBaudRate", input);
                    serialBaudRate = input;
                } catch (const genapi_error &err) {
                    if (err.genapi_error_code == ge::GENAPI_ERR_INVALID_ENUMERATION_STRING_VALUE) {
                        Tools::log("Invalid enumeration string value");
                    }
                }
            }
        }

        void setupEndOfLine() {
            std::string input;
            while (endOfLine.empty()) {
                Tools::log("Please choose EOL character used by the camera (CR/LF/CRLF):");
                std::getline(std::cin, input);
                if (input == "CR") {
                    endOfLine = "\r";
                } else if (input == "LF") {
                    endOfLine = "\n";
                } else if (input == "CRLF") {
                    endOfLine = "\r\n";
                } else {
                    Tools::log("Invalid value");
                }
            }
        }

        void setup() {
            setupBaudRate();
            setupEndOfLine();
            setInteger<DeviceModule>("SerialTimeout", serialTimeout);
            setInteger<DeviceModule>("SerialAccessBufferLength", serialAccessBufferLength);
        }

        bool isStillRunning(std::string &input) {
            do {
                Tools::log("Enter a command (enter :q to quit):");
                std::getline(std::cin, input);
                if (input == ":q") {
                    return false;
                }
            } while (input.empty());
            return true;
        }

        bool isDataIncoming(uint64_t timeoutMs) {
            uint64_t tStop = Tools::getTimestamp() + timeoutMs * 1000;
            while (Tools::getTimestamp() < tStop) {
                if (getInteger<DeviceModule>("SerialReadQueueSize")) {
                    return true;
                }
            }
            return false;
        }

        void checkSerialOperationStatus(bool throwOnFailure=false) {
            std::string status = getString<DeviceModule>("SerialOperationStatus");
            if (status != "Success") {
                 std::string operation = getString<DeviceModule>("SerialOperationSelector");
                 std::string message = operation + " " + status;
                 if (throwOnFailure) {
                     throw std::runtime_error(message);
                 } else {
                     Tools::log(message);
                 }
            }
        }

        void open() {
            setString<DeviceModule>("SerialOperationSelector", "Open");
            execute<DeviceModule>("SerialOperationExecute");
            checkSerialOperationStatus(true);
        }

        void close() {
            setString<DeviceModule>("SerialOperationSelector", "Close");
            execute<DeviceModule>("SerialOperationExecute");
            checkSerialOperationStatus();
        }

        std::string read(uint64_t n) {
            setString<DeviceModule>("SerialOperationSelector", "Read");
            if (n > serialAccessBufferLength) {
                n = serialAccessBufferLength;
            }
            setInteger<DeviceModule>("SerialAccessLength", n);
            execute<DeviceModule>("SerialOperationExecute");
            checkSerialOperationStatus();
            uint64_t readSize = getInteger<DeviceModule>("SerialOperationResult");
            std::vector<char> data(readSize);
            getRegister<DeviceModule>("SerialAccessBuffer", &data[0], data.size());
            return std::string(&data[0], data.size());
        }

        std::string readAvailableData() {
            return read(getInteger<DeviceModule>("SerialReadQueueSize"));
        }

        void write(const std::string &data) {
            setString<DeviceModule>("SerialOperationSelector", "Write");
            if (data.size() > serialAccessBufferLength) {
                Tools::log("Command size can not be greater than SerialAccessBufferLength (" +
                           Tools::toString(serialAccessBufferLength) +
                           ")");
                return;
            }
            setInteger<DeviceModule>("SerialAccessLength", data.size());
            setRegister<DeviceModule>("SerialAccessBuffer", data.data(), data.size());
            execute<DeviceModule>("SerialOperationExecute");
            checkSerialOperationStatus();
        }

        void flush() {
            setString<DeviceModule>("SerialOperationSelector", "Flush");
            execute<DeviceModule>("SerialOperationExecute");
            checkSerialOperationStatus();
        }

        void drain() {
            setString<DeviceModule>("SerialOperationSelector", "Drain");
            execute<DeviceModule>("SerialOperationExecute");
            checkSerialOperationStatus();
        }
};

static void sample() {
    EGenTL genTL(Grablink());
    MySerialCLIGrabber grabber(genTL);
    grabber.startCLI();
}

static Tools::Sample addSample(__FILE__, sample, "Command-line interface using GenApi commands for serial communication with a Camera Link camera");
