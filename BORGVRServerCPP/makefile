# Cross-platform Makefile (macOS + Linux) for borgvr_server_cpp
#
# Common targets:
#   make                         -> release build (default)
#   make CONFIG=debug            -> debug build
#   make clean                   -> remove build artifacts
#   make run ARGS="12345 64 /path/to/dataset.data" -> run the server
#
# Optional:
#   make ASAN=1                  -> build with sanitizers
#   make UNIVERSAL=1             -> macOS only: universal binary (arm64 + x86_64)

UNAME_S := $(shell uname -s)

# Toolchain defaults (override with: make CXX=...)
CXX ?= g++

TARGET    := borgvr_server

SRC_DIR   := src
INC_DIR   := include
BUILD_DIR := build

SRCS := $(wildcard $(SRC_DIR)/*.cpp)
OBJS := $(patsubst $(SRC_DIR)/%.cpp,$(BUILD_DIR)/obj/%.o,$(SRCS))
DEPS := $(OBJS:.o=.d)

CONFIG    ?= release
ASAN      ?= 0
UNIVERSAL ?= 0

CXXFLAGS_BASE := -std=c++17 -Wall -Wextra -Wpedantic -I$(INC_DIR) -MMD -MP
CXXFLAGS_BASE += -pthread
LDFLAGS_BASE  := -pthread

# macOS: universal binary (arm64 + x86_64)
ifeq ($(UNAME_S),Darwin)
  ifeq ($(UNIVERSAL),1)
    CXXFLAGS_BASE += -arch arm64 -arch x86_64
    LDFLAGS_BASE  += -arch arm64 -arch x86_64
  endif
endif

ifeq ($(CONFIG),debug)
  CXXFLAGS := $(CXXFLAGS_BASE) -O0 -g -DDEBUG
else ifeq ($(CONFIG),release)
  CXXFLAGS := $(CXXFLAGS_BASE) -O2 -DNDEBUG
else
  $(error Unknown CONFIG '$(CONFIG)'. Use CONFIG=debug or CONFIG=release.)
endif

# Sanitizers (useful for catching memory bugs)
ifeq ($(ASAN),1)
  CXXFLAGS += -fsanitize=address,undefined -fno-omit-frame-pointer
  LDFLAGS  := $(LDFLAGS_BASE) -fsanitize=address,undefined
else
  LDFLAGS  := $(LDFLAGS_BASE)
endif

.PHONY: all clean run print-vars

all: $(BUILD_DIR)/$(TARGET)

$(BUILD_DIR)/$(TARGET): $(OBJS)
	@mkdir -p $(dir $@)
	$(CXX) $(OBJS) -o $@ $(LDFLAGS)

$(BUILD_DIR)/obj/%.o: $(SRC_DIR)/%.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c $< -o $@

run: all
	./$(BUILD_DIR)/$(TARGET) $(ARGS)

clean:
	rm -rf $(BUILD_DIR)

print-vars:
	@echo "UNAME_S=$(UNAME_S)"
	@echo "CONFIG=$(CONFIG)"
	@echo "ASAN=$(ASAN)"
	@echo "UNIVERSAL=$(UNIVERSAL)"
	@echo "CXX=$(CXX)"
	@echo "CXXFLAGS=$(CXXFLAGS)"
	@echo "LDFLAGS=$(LDFLAGS)"
	@echo "SRCS=$(SRCS)"

-include $(DEPS)
