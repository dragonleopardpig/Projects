UNAME := $(shell uname -s)
BUILDARCH := $(shell uname -m)
CXX = g++
TARGET = displayLatestBuffer
CXXFLAGS = `sdl2-config --cflags`
LDFLAGS = `sdl2-config --libs`

ifeq ($(UNAME),Darwin)
INCLUDE_COAXLINK_HEADERS = -I/usr/local/opt/euresys/egrabber/include
else
INCLUDE_COAXLINK_HEADERS = -I/opt/euresys/egrabber/include
LDFLAGS += -pthread
LDFLAGS += -ldl
LDFLAGS += -lrt
endif

CXXFLAGS += -Wall -O3 -std=c++11 -pthread -DWINDOW_TITLE="\"eGrabber sample: $(TARGET)\""
CXXFLAGS += $(INCLUDE_COAXLINK_HEADERS)

ifeq ($(BUILDARCH),aarch64)
CXXFLAGS += -mfpu=neon
endif

VPATH = ../common
SRCS = $(TARGET).cpp window.cpp
OBJS = $(SRCS:.cpp=.o)

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CXX) -o $(TARGET) $(OBJS) $(LDFLAGS)

%.o: %.cpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

clean:
	rm -f $(TARGET) $(OBJS)
