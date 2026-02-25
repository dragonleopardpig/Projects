BUILD_DIR ?= build
TARGET ?= egrabber-samples

ifneq ($(OS),Windows_NT)
# Please use the Visual Studio solutions on Windows to compile the CUDA samples.
NVCC = nvcc
WHICH_NVCC = $(shell which $(NVCC) 2>/dev/null)
ifneq ($(WHICH_NVCC),)
NVCC_DIR := $(shell dirname "$(WHICH_NVCC)")
endif

ifeq ($(shell uname -s),Darwin)
INCLUDE_COAXLINK_HEADERS = -I/usr/local/opt/euresys/egrabber/include
else
INCLUDE_COAXLINK_HEADERS = -I/opt/euresys/egrabber/include
LDFLAGS += -pthread
LDFLAGS += -ldl
LDFLAGS += -lrt
endif
endif


CFLAGS += -Wall -g -std=c++11 -pthread
CFLAGS += $(INCLUDE_COAXLINK_HEADERS)

ifneq ($(NVCC_DIR),)
C_SAMPLES  = $(wildcard samples/*.cpp)
O_CUDA     = $(CUDA_SOURCES:samples/%.cu=$(BUILD_DIR)/samples/%.cuo)
CUDA_LIBS  = -lcuda -lcudart
CUDA_INC   = -I"$(NVCC_DIR)/../include"
CUDA_FLAGS = $(INCLUDE_COAXLINK_HEADERS) $(CUDA_INC)
LDFLAGS   += -L"$(NVCC_DIR)/../lib64"
CFLAGS    += $(CUDA_INC)
else
CUDA_CPP_SRC = $(wildcard samples/*-cuda-*.cpp)
C_SAMPLES    = $(filter-out $(CUDA_CPP_SRC),$(wildcard samples/*.cpp))
O_CUDA       =
CUDA_LIBS    =
CUDA_INC     =
endif

C_TOOLS      = $(wildcard tools/*.cpp)
CUDA_SOURCES = $(wildcard samples/*.cu)

O_SAMPLES = $(C_SAMPLES:samples/%.cpp=$(BUILD_DIR)/samples/%.o)
O_TOOLS   = $(C_TOOLS:tools/%.cpp=$(BUILD_DIR)/tools/%.o)

.PHONY: all clean
.DEFAULT: all

all: $(TARGET)

$(TARGET): $(O_SAMPLES) $(O_TOOLS) $(O_CUDA)
	$(CXX) -o $@ $^ $(LDFLAGS) $(CUDA_LIBS)

build_samples:
	mkdir -p $(BUILD_DIR)/samples

build_cuda:
	mkdir -p $(BUILD_DIR)/samples

build_tools:
	mkdir -p $(BUILD_DIR)/tools

$(BUILD_DIR)/samples/%.o: samples/%.cpp | build_samples
	$(CXX) -c $< -o $@ $(CFLAGS)

$(BUILD_DIR)/tools/%.o: tools/%.cpp | build_tools
	$(CXX) -c $< -o $@ $(CFLAGS)

$(BUILD_DIR)/samples/%.cuo: samples/%.cu | build_cuda
	$(NVCC) -c $< -o $@ $(CUDA_FLAGS)

clean:
	rm -f $(TARGET)
	rm -rf $(BUILD_DIR)

