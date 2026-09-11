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
WEB_DIR   := ../web
SCRIPT_DIR := scripts

GENERATED_WEB_SRC := $(SRC_DIR)/GeneratedWebAssets.cpp
GENERATED_WEB_HDR := $(SRC_DIR)/GeneratedWebAssets.h
WEB_EMBED_SCRIPT := $(SCRIPT_DIR)/embed_web_assets.py
WEB_ASSETS := $(shell find $(WEB_DIR) -type f ! -name '.*' 2>/dev/null)

SRCS := $(filter-out $(GENERATED_WEB_SRC),$(wildcard $(SRC_DIR)/*.cpp)) $(GENERATED_WEB_SRC)
OBJS := $(patsubst $(SRC_DIR)/%.cpp,$(BUILD_DIR)/obj/%.o,$(SRCS))
DEPS := $(OBJS:.o=.d)

CONFIG    ?= release
ASAN      ?= 0
UNIVERSAL ?= 0
BUILD_TIMESTAMP ?= $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")
BORGVR_SERVER_VERSION ?= 2.0

CXXFLAGS_BASE := -std=c++17 -Wall -Wextra -Wpedantic -I$(INC_DIR) -MMD -MP
CXXFLAGS_BASE += -pthread
LDFLAGS_BASE  := -pthread
BUILD_ID_FLAGS := -DBORGVR_BUILD_TIMESTAMP=\"$(BUILD_TIMESTAMP)\" -DBORGVR_SERVER_VERSION=\"$(BORGVR_SERVER_VERSION)\"

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

.PHONY: all clean run print-vars FORCE

all: $(BUILD_DIR)/$(TARGET)

$(GENERATED_WEB_SRC) $(GENERATED_WEB_HDR): $(WEB_ASSETS) $(WEB_EMBED_SCRIPT)
	python3 $(WEB_EMBED_SCRIPT) --web-dir $(WEB_DIR) --out-dir $(SRC_DIR)

$(BUILD_DIR)/$(TARGET): $(OBJS)
	@mkdir -p $(dir $@)
	$(CXX) $(OBJS) -o $@ $(LDFLAGS)

$(BUILD_DIR)/obj/main.o: $(SRC_DIR)/main.cpp FORCE
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) $(BUILD_ID_FLAGS) -c $< -o $@

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
	@echo "BUILD_TIMESTAMP=$(BUILD_TIMESTAMP)"
	@echo "BORGVR_SERVER_VERSION=$(BORGVR_SERVER_VERSION)"
	@echo "CXX=$(CXX)"
	@echo "CXXFLAGS=$(CXXFLAGS)"
	@echo "LDFLAGS=$(LDFLAGS)"
	@echo "SRCS=$(SRCS)"

-include $(DEPS)

# Copyright (c) 2026 Computer Graphics and Visualization Group, University of Duisburg-Essen
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this
# software and associated documentation files (the "Software"), to deal in the Software
# without restriction, including without limitation the rights to use, copy, modify,
# merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to the following
# conditions:
#
# The above copyright notice and this permission notice shall be included in all copies or
# substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
# INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
# PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
# BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
# OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
# IN THE SOFTWARE.
