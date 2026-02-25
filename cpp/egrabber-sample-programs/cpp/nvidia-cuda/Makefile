NVCC = nvcc
WHICH_NVCC = $(shell which $(NVCC) 2>/dev/null)
ifneq ($(WHICH_NVCC),)
NVCC_DIR := $(shell dirname "$(WHICH_NVCC)")
endif

GL_LIBS   = -lGL -lGLU -lGLEW -lglut

CFLAGS += -Wall -g -pthread
CFLAGS += -I/opt/euresys/egrabber/include

ifneq ($(NVCC_DIR),)
CUDA_INC   = -I"$(NVCC_DIR)/../include"
CUDA_FLAGS = $(CUDA_INC) -Wno-deprecated-declarations
CFLAGS    += $(CUDA_INC)
CUDA_LIBS = -lcuda -lcudart
LDFLAGS   += -L"$(NVCC_DIR)/../lib64" -pthread
endif

CPP_SOURCES  = $(wildcard src/*.cpp)
CUDA_SOURCES = $(wildcard src/*.cu)

O_CPP  = $(CPP_SOURCES:src/%.cpp=build/cpp/%.o)
O_CUDA = $(CUDA_SOURCES:src/%.cu=build/cuda/%.o)

TARGET = egrabber-cuda

.PHONY: all clean
.DEFAULT: all

all: $(TARGET) config.js

egrabber-cuda: $(O_CPP) $(O_CUDA)
	$(CXX) -o $@ $^ -ldl $(GL_LIBS) $(CUDA_LIBS) $(LDFLAGS)

config.js: src/config.js
	ln -s $< $@

build_cpp:
	mkdir -p build/cpp

build_cuda:
	mkdir -p build/cuda

build/cpp/%.o: src/%.cpp | build_cpp
	$(CXX) -c $< -o $@ $(CFLAGS)

build/cuda/%.o: src/%.cu | build_cuda
	$(NVCC) -c $< -o $@ $(CUDA_FLAGS)

clean: src Makefile
	rm -f $(TARGET)
	rm -rf build
