#pragma once

#include <chrono>
#include <ctime>
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
  explicit Logger(LogLevel minLevel = LogLevel::Info) : minLevel_(minLevel) {}

  void setMinLevel(LogLevel lvl) { minLevel_ = lvl; }

  void debug(const std::string& msg) { log(LogLevel::Debug, "DEBUG", msg); }
  void info(const std::string& msg) { log(LogLevel::Info, "INFO", msg); }
  void warning(const std::string& msg) { log(LogLevel::Warning, "WARN", msg); }
  void error(const std::string& msg) { log(LogLevel::Error, "ERROR", msg); }

private:
  static std::string timestamp() {
    using clock = std::chrono::system_clock;
    const auto now = clock::now();
    const auto tt = clock::to_time_t(now);
    const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                      now.time_since_epoch()) %
                    1000;

    std::tm tm{};
#if defined(_WIN32)
    localtime_s(&tm, &tt);
#else
    localtime_r(&tt, &tm);
#endif

    std::ostringstream oss;
    oss << std::put_time(&tm, "%Y-%m-%d %H:%M:%S") << "." << std::setw(3)
        << std::setfill('0') << ms.count();
    return oss.str();
  }

  void log(LogLevel lvl, const char* tag, const std::string& msg) {
    if (static_cast<int>(lvl) < static_cast<int>(minLevel_)) {
      return;
    }
    std::lock_guard<std::mutex> lock(mu_);
    std::cerr << timestamp() << " [" << tag << "] " << msg << "\n";
  }

  std::mutex mu_;
  LogLevel minLevel_;
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
