UNAME := $(shell uname -s)
BUILDARCH := $(shell uname -m)
CXX = g++
TARGET = egrabber-cuda-sdl2
CXXFLAGS = `sdl2-config --cflags`
LDFLAGS = `sdl2-config --libs`

NVCC = nvcc
WHICH_NVCC = $(shell which $(NVCC) 2>/dev/null)
ifneq ($(WHICH_NVCC),)
NVCC_DIR := $(shell dirname "$(WHICH_NVCC)")
endif
ifeq ($(UNAME),Darwin)
INCLUDE_COAXLINK_HEADERS = -I/usr/local/opt/euresys/egrabber/include
else
INCLUDE_COAXLINK_HEADERS = -I/opt/euresys/egrabber/include
LDFLAGS += -pthread
LDFLAGS += -ldl
LDFLAGS += -lrt
endif

CXXFLAGS += -Wall -O3 -std=c++11 -pthread
CXXFLAGS += $(INCLUDE_COAXLINK_HEADERS) -I../common

ifeq ($(BUILDARCH),aarch64)
CXXFLAGS += -mfpu=neon
endif

CUDA_INC   = -I"$(NVCC_DIR)/../include"
CXXFLAGS  += $(CUDA_INC)
CUDA_FLAGS = $(INCLUDE_COAXLINK_HEADERS) $(CUDA_INC)
LDFLAGS   += -L"$(NVCC_DIR)/../lib64"
CUDA_LIBS  = -lcuda -lcudart
CUDA_OBJS  = kernel.cuo

vpath %.cpp src ../common
vpath %.cu src
SRCS = main.cpp window.cpp
OBJS = $(SRCS:.cpp=.o) $(CUDA_OBJS)

all: $(TARGET) config.js

$(TARGET): $(OBJS)
	$(CXX) -o $(TARGET) $(OBJS) $(LDFLAGS) $(CUDA_LIBS)

config.js: src/config.js
	ln -s $< $@

%.o: %.cpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

%.cuo: %.cu
	$(NVCC) $(CUDA_FLAGS) -c $< -o $@

clean:
	rm -f $(TARGET) $(OBJS) config.js
