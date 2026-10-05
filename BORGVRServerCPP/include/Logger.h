#pragma once

#include <iostream>
#include <mutex>
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
      : minLevel_(minLevel), useColors_(useColors) {}

  void setMinLevel(LogLevel lvl) { minLevel_ = lvl; }

  void debug(const std::string& msg) { log(LogLevel::Debug, "DEBUG", msg); }
  void info(const std::string& msg) { log(LogLevel::Info, "INFO", msg); }
  void warning(const std::string& msg) { log(LogLevel::Warning, "WARNING", msg); }
  void error(const std::string& msg) { log(LogLevel::Error, "ERROR", msg); }

private:
  void log(LogLevel lvl, const char* tag, const std::string& msg) {
    if (static_cast<int>(lvl) < static_cast<int>(minLevel_)) {
      return;
    }
    std::lock_guard<std::mutex> lock(mu_);
    const char* color = "";
    if (useColors_) {
      switch (lvl) {
        case LogLevel::Debug: color = "\033[36m"; break;
        case LogLevel::Info: color = "\033[32m"; break;
        case LogLevel::Warning: color = "\033[33m"; break;
        case LogLevel::Error: color = "\033[31m"; break;
      }
    }
    std::cerr << color << "[" << tag << "] " << msg;
    if (useColors_) std::cerr << "\033[0m";
    std::cerr << "\n";
  }

  std::mutex mu_;
  LogLevel minLevel_;
  bool useColors_;
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
