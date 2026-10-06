#pragma once

#include <atomic>
#include <chrono>
#include <cstdint>
#include <ctime>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <sstream>
#include <string>

enum class LogLevel {
  Debug = 0,
  Info = 1,
  Warning = 2,
  Error = 3
};

class Logger {
public:
  explicit Logger(LogLevel minLevel = LogLevel::Info, bool useColors = true)
      : minLevel_(static_cast<int>(minLevel)), useColors_(useColors) {}

  void setMinLevel(LogLevel lvl) {
    minLevel_.store(static_cast<int>(lvl), std::memory_order_relaxed);
  }

  LogLevel minLevel() const {
    return static_cast<LogLevel>(minLevel_.load(std::memory_order_relaxed));
  }

  bool setLogFile(const std::string& path) {
    std::lock_guard<std::mutex> lock(mu_);
    file_.close();
    file_.clear();
    file_.open(path, std::ios::out | std::ios::app);
    return file_.is_open();
  }

  void debug(const std::string& msg) { log(LogLevel::Debug, "DEBUG", msg); }
  void info(const std::string& msg) { log(LogLevel::Info, "INFO", msg); }
  void warning(const std::string& msg) { log(LogLevel::Warning, "WARNING", msg); }
  void error(const std::string& msg) { log(LogLevel::Error, "ERROR", msg); }

private:
  static bool isUnsafeCodePoint(uint32_t codePoint) {
    return codePoint < 0x20 ||
           (codePoint >= 0x7f && codePoint <= 0x9f) ||
           codePoint == 0x00ad ||
           codePoint == 0x061c ||
           (codePoint >= 0x200b && codePoint <= 0x200f) ||
           (codePoint >= 0x2028 && codePoint <= 0x202e) ||
           (codePoint >= 0x2060 && codePoint <= 0x206f) ||
           codePoint == 0xfeff ||
           (codePoint >= 0xfff9 && codePoint <= 0xfffb);
  }

  static void appendEscapedByte(std::string& output, uint8_t byte) {
    constexpr char hex[] = "0123456789ABCDEF";
    output += "\\x";
    output.push_back(hex[(byte >> 4) & 0x0f]);
    output.push_back(hex[byte & 0x0f]);
  }

  static void appendEscapedCodePoint(std::string& output, uint32_t codePoint) {
    constexpr char hex[] = "0123456789ABCDEF";
    output += "\\u{";
    char digits[8];
    size_t count = 0;
    do {
      digits[count++] = hex[codePoint & 0x0f];
      codePoint >>= 4;
    } while (codePoint != 0);
    while (count > 0) {
      output.push_back(digits[--count]);
    }
    output.push_back('}');
  }

  static std::string sanitize(const std::string& message) {
    std::string output;
    output.reserve(message.size());

    size_t index = 0;
    while (index < message.size()) {
      const auto first = static_cast<uint8_t>(message[index]);
      uint32_t codePoint = 0;
      size_t sequenceLength = 0;
      uint32_t minimumCodePoint = 0;

      if (first < 0x80) {
        codePoint = first;
        sequenceLength = 1;
      } else if ((first & 0xe0) == 0xc0) {
        codePoint = first & 0x1f;
        sequenceLength = 2;
        minimumCodePoint = 0x80;
      } else if ((first & 0xf0) == 0xe0) {
        codePoint = first & 0x0f;
        sequenceLength = 3;
        minimumCodePoint = 0x800;
      } else if ((first & 0xf8) == 0xf0) {
        codePoint = first & 0x07;
        sequenceLength = 4;
        minimumCodePoint = 0x10000;
      } else {
        appendEscapedByte(output, first);
        ++index;
        continue;
      }

      bool valid = index + sequenceLength <= message.size();
      for (size_t offset = 1; valid && offset < sequenceLength; ++offset) {
        const auto continuation = static_cast<uint8_t>(message[index + offset]);
        if ((continuation & 0xc0) != 0x80) {
          valid = false;
          break;
        }
        codePoint = (codePoint << 6) | (continuation & 0x3f);
      }
      valid = valid &&
              codePoint >= minimumCodePoint &&
              codePoint <= 0x10ffff &&
              !(codePoint >= 0xd800 && codePoint <= 0xdfff);
      if (!valid) {
        appendEscapedByte(output, first);
        ++index;
        continue;
      }

      if (isUnsafeCodePoint(codePoint)) {
        appendEscapedCodePoint(output, codePoint);
      } else {
        output.append(message, index, sequenceLength);
      }
      index += sequenceLength;
    }
    return output;
  }

  static std::string timestamp() {
    const auto now = std::chrono::system_clock::now();
    const std::time_t time = std::chrono::system_clock::to_time_t(now);
    std::tm localTime{};
#if defined(_WIN32)
    localtime_s(&localTime, &time);
#else
    localtime_r(&time, &localTime);
#endif
    std::ostringstream stream;
    stream << std::put_time(&localTime, "%Y-%m-%dT%H:%M:%S%z");
    return stream.str();
  }

  void log(LogLevel lvl, const char* tag, const std::string& msg) {
    if (static_cast<int>(lvl) < minLevel_.load(std::memory_order_relaxed)) {
      return;
    }
    std::lock_guard<std::mutex> lock(mu_);
    const std::string safeMessage = sanitize(msg);
    const char* color = "";
    if (useColors_) {
      switch (lvl) {
        case LogLevel::Debug: color = "\033[36m"; break;
        case LogLevel::Info: color = "\033[32m"; break;
        case LogLevel::Warning: color = "\033[33m"; break;
        case LogLevel::Error: color = "\033[31m"; break;
      }
    }
    if (useColors_) std::cerr << "\033(B\017";
    std::cerr << color << "[" << tag << "] " << safeMessage;
    if (useColors_) std::cerr << "\033(B\017\033[0m";
    std::cerr << "\n";
    if (file_.is_open()) {
      file_ << timestamp() << " [" << tag << "] " << safeMessage << "\n";
      file_.flush();
    }
  }

  std::mutex mu_;
  std::atomic<int> minLevel_;
  bool useColors_;
  std::ofstream file_;
};

/*
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of Duisburg-Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of this
 software and associated documentation files (the "Software"), to deal in the Software
 without restriction, including without limitation the rights to use, copy, modify,
 merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 permit persons to whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included in all copies or
 substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
 BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
 OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
 IN THE SOFTWARE.
 */
