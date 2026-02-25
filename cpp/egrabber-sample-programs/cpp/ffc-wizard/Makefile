BUILD_DIR ?= build
TARGET ?= ffc-wizard

ifneq ($(OS),Windows_NT)
ifeq ($(shell uname -s),Darwin)
INCLUDE_COAXLINK_HEADERS = -I/usr/local/opt/euresys/egrabber/include
else
INCLUDE_COAXLINK_HEADERS = -I/opt/euresys/egrabber/include
LDFLAGS += -pthread
LDFLAGS += -ldl
endif
endif

CFLAGS += -Wall -g -pthread
CFLAGS += $(INCLUDE_COAXLINK_HEADERS)

C_SRCS = $(wildcard src/*.cpp)

O_SRCS = $(C_SRCS:src/%.cpp=$(BUILD_DIR)/obj/%.o)

.PHONY: all clean
.DEFAULT: all

all: $(TARGET)

$(TARGET): $(O_SRCS)
	$(CXX) -o $@ $^ $(LDFLAGS)

build:
	mkdir -p $(BUILD_DIR)/obj

$(BUILD_DIR)/obj/%.o: src/%.cpp | build
	$(CXX) -c $< -o $@ $(CFLAGS)

clean:
	rm -f $(TARGET)
	rm -rf $(BUILD_DIR)

