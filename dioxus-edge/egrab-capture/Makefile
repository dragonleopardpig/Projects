CXX = g++
CXXFLAGS = -std=c++14 -O2 -Wall
INCLUDES = -I/opt/euresys/egrabber/include
LDFLAGS = -L/opt/euresys/egrabber/lib/x86_64 -legrabber -ldl -lpthread

TARGET = egrab-capture
SRC = capture.cpp

all: $(TARGET)

$(TARGET): $(SRC)
	$(CXX) $(CXXFLAGS) $(INCLUDES) -o $@ $< $(LDFLAGS)

clean:
	rm -f $(TARGET)

.PHONY: all clean
