#include "HTTPWebServer.h"
#include "TCPServer.h"
#include "BORGVRMetaData.h"
#include "Logger.h"
#include "Socket.h"

#include <array>
#include <atomic>
#include <cctype>
#include <cstdint>
#include <exception>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <sstream>
#include <thread>
#include <unordered_set>
#include <vector>

#ifndef BORGVR_BUILD_TIMESTAMP
#define BORGVR_BUILD_TIMESTAMP "unknown"
#endif

static std::string basenameOf(const std::string& path) {
  const auto slash = path.find_last_of("/\\");
  if (slash == std::string::npos) return path;
  return path.substr(slash + 1);
}

static bool parseUint16(const std::string& s, uint16_t& out) {
  try {
    size_t idx = 0;
    int v = std::stoi(s, &idx, 10);
    if (idx != s.size()) return false;
    if (v <= 0 || v > 65535) return false;
    out = static_cast<uint16_t>(v);
    return true;
  } catch (...) {
    return false;
  }
}

static bool parseInt(const std::string& s, int& out) {
  try {
    size_t idx = 0;
    int v = std::stoi(s, &idx, 10);
    if (idx != s.size()) return false;
    out = v;
    return true;
  } catch (...) {
    return false;
  }
}

static void printUsage(const char* filename) {
  std::cout << "Usage:\n  " << basenameOf(filename)
            << " port maxBricksPerGetRequest datasetDirectory [scanIntervalSeconds]\n"
            << "    [--password secret]\n"
            << "    [--web-port port]\n\n"
            << "Examples:\n"
            << "  " << basenameOf(filename) << " 12345 64 /data/BorgVR\n"
            << "  " << basenameOf(filename) << " 12345 64 /data/BorgVR --web-port 8080\n";
}

static void printStartupBanner(uint16_t port,
                               int maxBricks,
                               const std::string& datasetDir,
                               uint16_t webPort,
                               int scanIntervalSeconds,
                               bool passwordProtected) {
  std::cout
    << "\n"
    << "  ____                   __     ______\n"
    << " | __ )  ___  _ __ __ _ \\ \\   / /  _ \\\n"
    << " |  _ \\ / _ \\| '__/ _` | \\ \\ / /| |_) |\n"
    << " | |_) | (_) | | | (_| |  \\ V / |  _ <\n"
    << " |____/ \\___/|_|  \\__, |   \\_/  |_| \\_\\\n"
    << "                  |___/\n"
    << "\n"
    << " BorgVR Dataset Server\n"
    << " ------------------------------------------------------------\n"
    << " Build             : " << BORGVR_BUILD_TIMESTAMP << "\n"
    << " Dataset directory : " << datasetDir << "\n"
    << " Dataset port      : " << port << "\n"
    << " Max brick batch   : " << maxBricks << "\n"
    << " Scan interval     : " << scanIntervalSeconds << " s\n"
    << " Password          : " << (passwordProtected ? "enabled" : "disabled") << "\n";

  if (webPort > 0) {
    std::cout << " WebGPU preview    : http://localhost:" << webPort << "\n";
  } else {
    std::cout << " WebGPU preview    : disabled\n";
  }

  std::cout
    << " ------------------------------------------------------------\n"
    << "\n"
    << std::flush;
}

static void logDatasetScanFailureOnce(const std::string& filename,
                                      const std::string& reason,
                                      std::shared_ptr<Logger> logger) {
  if (!logger) return;

  static std::mutex mutex;
  static std::unordered_set<std::string> reportedFiles;

  std::lock_guard<std::mutex> lock(mutex);
  if (reportedFiles.insert(filename).second) {
    logger->warning("Unable to load dataset file " + filename + ": " + reason);
  }
}

static uint32_t leftRotate(uint32_t value, uint32_t shift) {
  return (value << shift) | (value >> (32 - shift));
}

static std::string md5Hex(const uint8_t* input, size_t inputLength) {
  static constexpr uint32_t shifts[64] = {
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21
  };

  static constexpr uint32_t constants[64] = {
    0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
    0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
    0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
    0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
    0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
    0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
    0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
    0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
    0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
    0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
    0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
    0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
    0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
    0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
    0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
    0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391
  };

  std::vector<uint8_t> message(input, input + inputLength);
  const uint64_t bitLength = static_cast<uint64_t>(inputLength) * 8;
  message.push_back(0x80);
  while ((message.size() % 64) != 56) {
    message.push_back(0);
  }
  for (int i = 0; i < 8; ++i) {
    message.push_back(static_cast<uint8_t>((bitLength >> (8 * i)) & 0xff));
  }

  uint32_t a0 = 0x67452301;
  uint32_t b0 = 0xefcdab89;
  uint32_t c0 = 0x98badcfe;
  uint32_t d0 = 0x10325476;

  for (size_t offset = 0; offset < message.size(); offset += 64) {
    uint32_t words[16];
    for (int i = 0; i < 16; ++i) {
      const size_t j = offset + static_cast<size_t>(i) * 4;
      words[i] = static_cast<uint32_t>(message[j]) |
                 (static_cast<uint32_t>(message[j + 1]) << 8) |
                 (static_cast<uint32_t>(message[j + 2]) << 16) |
                 (static_cast<uint32_t>(message[j + 3]) << 24);
    }

    uint32_t a = a0;
    uint32_t b = b0;
    uint32_t c = c0;
    uint32_t d = d0;

    for (uint32_t i = 0; i < 64; ++i) {
      uint32_t f = 0;
      uint32_t g = 0;
      if (i < 16) {
        f = (b & c) | ((~b) & d);
        g = i;
      } else if (i < 32) {
        f = (d & b) | ((~d) & c);
        g = (5 * i + 1) % 16;
      } else if (i < 48) {
        f = b ^ c ^ d;
        g = (3 * i + 5) % 16;
      } else {
        f = c ^ (b | (~d));
        g = (7 * i) % 16;
      }

      const uint32_t temp = d;
      d = c;
      c = b;
      b = b + leftRotate(a + f + constants[i] + words[g], shifts[i]);
      a = temp;
    }

    a0 += a;
    b0 += b;
    c0 += c;
    d0 += d;
  }

  std::ostringstream oss;
  oss << std::hex << std::setfill('0');
  for (uint32_t value : {a0, b0, c0, d0}) {
    for (int i = 0; i < 4; ++i) {
      oss << std::setw(2) << static_cast<int>((value >> (8 * i)) & 0xff);
    }
  }
  return oss.str();
}

static bool readFileBytes(const std::string& filename, std::vector<uint8_t>& out) {
  std::ifstream file(filename, std::ios::binary);
  if (!file) return false;
  out.assign(std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>());
  return true;
}

static uint32_t readU32LE(const std::vector<uint8_t>& bytes, size_t offset) {
  return static_cast<uint32_t>(bytes[offset]) |
         (static_cast<uint32_t>(bytes[offset + 1]) << 8) |
         (static_cast<uint32_t>(bytes[offset + 2]) << 16) |
         (static_cast<uint32_t>(bytes[offset + 3]) << 24);
}

static std::string trimCopy(const std::string& text) {
  size_t start = 0;
  while (start < text.size() && std::isspace(static_cast<unsigned char>(text[start]))) {
    ++start;
  }
  size_t end = text.size();
  while (end > start && std::isspace(static_cast<unsigned char>(text[end - 1]))) {
    --end;
  }
  return text.substr(start, end - start);
}

static bool parseTransferFunctionFile(const std::string& filename,
                                      TransferFunctionInfo& out,
                                      std::string& reason) {
  std::vector<uint8_t> bytes;
  if (!readFileBytes(filename, bytes)) {
    reason = "unable to read file";
    return false;
  }
  if (bytes.size() < 4) {
    reason = "file too small";
    return false;
  }

  size_t cursor = 0;
  std::string description;
  uint32_t count = 0;
  const bool hasExtendedHeader =
    bytes.size() >= 4 &&
    bytes[0] == 'B' && bytes[1] == 'T' && bytes[2] == 'F' && bytes[3] == '1';

  if (hasExtendedHeader) {
    cursor = 4;
    if (bytes.size() < cursor + 12) {
      reason = "extended header too small";
      return false;
    }
    const uint32_t version = readU32LE(bytes, cursor);
    cursor += 4;
    if (version != 2) {
      reason = "unsupported transfer function version";
      return false;
    }
    const uint32_t descriptionByteCount = readU32LE(bytes, cursor);
    cursor += 4;
    count = readU32LE(bytes, cursor);
    cursor += 4;
    if (descriptionByteCount > bytes.size() - cursor) {
      reason = "description exceeds file size";
      return false;
    }
    description.assign(reinterpret_cast<const char*>(bytes.data() + cursor), descriptionByteCount);
    cursor += descriptionByteCount;
  } else {
    count = readU32LE(bytes, cursor);
    cursor += 4;
  }

  if (static_cast<size_t>(count) > std::numeric_limits<size_t>::max() / 4) {
    reason = "transfer function sample count is too large";
    return false;
  }
  const size_t rgbaByteCount = static_cast<size_t>(count) * 4;
  if (rgbaByteCount > bytes.size() - cursor) {
    reason = "RGBA payload exceeds file size";
    return false;
  }

  const auto basename = basenameOf(filename);
  const auto dot = basename.find_last_of('.');
  const std::string fallbackName = dot == std::string::npos ? basename : basename.substr(0, dot);

  out.id = md5Hex(bytes.data() + cursor, rgbaByteCount);
  out.filename = filename;
  const std::string trimmedDescription = trimCopy(description);
  out.transferFunctionDescription = trimmedDescription.empty() ? fallbackName : trimmedDescription;
  out.byteCount = bytes.size();
  return true;
}

static std::vector<DatasetInfo> scanDatasetDirectory(const std::string& directory,
                                                     std::shared_ptr<Logger> logger) {
  namespace fs = std::filesystem;

  std::vector<DatasetInfo> datasets;
  std::error_code ec;
  if (!fs::exists(directory, ec) || !fs::is_directory(directory, ec)) {
    if (logger) logger->error("Not a directory: " + directory);
    return datasets;
  }

  for (const auto& entry : fs::directory_iterator(directory, ec)) {
    if (ec) break;
    if (!entry.is_regular_file(ec)) continue;

    const auto path = entry.path();
    if (path.extension() != ".data") continue;

    const std::string filename = path.string();
    try {
      BORGVRMetaData md(filename);
      DatasetInfo info;
      info.id = md.uniqueID();
      info.filename = filename;
      info.datasetDescription = md.datasetDescription();
      datasets.push_back(std::move(info));
    } catch (const std::exception& e) {
      logDatasetScanFailureOnce(filename, e.what(), logger);
    } catch (...) {
      logDatasetScanFailureOnce(filename, "unknown error", logger);
    }
  }

  return datasets;
}

static std::vector<TransferFunctionInfo> scanTransferFunctionDirectory(const std::string& directory,
                                                                       std::shared_ptr<Logger> logger) {
  namespace fs = std::filesystem;

  std::vector<TransferFunctionInfo> transferFunctions;
  std::error_code ec;
  if (!fs::exists(directory, ec) || !fs::is_directory(directory, ec)) {
    return transferFunctions;
  }

  for (const auto& entry : fs::directory_iterator(directory, ec)) {
    if (ec) break;
    if (!entry.is_regular_file(ec)) continue;

    const auto path = entry.path();
    if (path.extension() != ".tf1d") continue;

    TransferFunctionInfo info;
    std::string reason;
    const std::string filename = path.string();
    if (parseTransferFunctionFile(filename, info, reason)) {
      transferFunctions.push_back(std::move(info));
    } else if (logger) {
      logger->warning("Unable to load transfer function file " + filename + ": " + reason);
    }
  }

  return transferFunctions;
}

int main(int argc, char** argv) {
  SocketSystem sockSys;
  auto logger = std::make_shared<Logger>(LogLevel::Info);

  const bool wantsHelp = argc >= 2 && (std::string(argv[1]) == "--help" || std::string(argv[1]) == "-h");
  if (wantsHelp || argc < 4) {
    printUsage(argv[0]);
    return wantsHelp ? 0 : 1;
  }

  uint16_t port = 0;
  if (!parseUint16(argv[1], port)) {
    std::stringstream ss;
    ss << "Invalid port: " << argv[1] << "\n";
    logger->error(ss.str());
    return 1;
  }

  int maxBricks = 64;
  int argi = 2;
  if (argc >= 3) {
    int tmp = 0;
    if (parseInt(argv[2], tmp)) {
      maxBricks = tmp;
      argi = 3;
    }
  }
  const std::string datasetDir = argv[argi++];

  int scanIntervalSeconds = 10;
  if (argc > argi) {
    int tmp = 0;
    if (parseInt(argv[argi], tmp) && tmp > 0) {
      scanIntervalSeconds = tmp;
      ++argi;
    }
  }

  std::string password;
  uint16_t webPort = 0;
  while (argc > argi) {
    const std::string option = argv[argi++];
    if (option == "--password") {
      if (argc <= argi) {
        logger->error("Missing value for --password");
        return 1;
      }
      password = argv[argi++];
    } else if (option == "--web-port") {
      if (argc <= argi) {
        logger->error("Missing value for --web-port");
        return 1;
      }
      if (!parseUint16(argv[argi], webPort)) {
        logger->error(std::string("Invalid web port: ") + argv[argi]);
        return 1;
      }
      ++argi;
    } else {
      logger->error("Unknown argument: " + option);
      printUsage(argv[0]);
      return 1;
    }
  }

  printStartupBanner(port, maxBricks, datasetDir, webPort, scanIntervalSeconds, !password.empty());

  auto datasets = scanDatasetDirectory(datasetDir, logger);
  auto transferFunctions = scanTransferFunctionDirectory(datasetDir, logger);

  TCPServer server(port, maxBricks, logger, password);
  server.setDatasets(datasets);
  server.setTransferFunctions(transferFunctions);
  if (!server.start()) {
    return 2;
  }

  std::unique_ptr<HTTPWebServer> webServer;
  if (webPort > 0) {
    webServer = std::make_unique<HTTPWebServer>(webPort, server, logger, password);
    if (!webServer->start()) {
      server.stop();
      return 3;
    }
  }

  std::atomic<bool> monitorRunning{true};
  std::thread monitorThread([&]() {
    while (monitorRunning.load()) {
      const auto refreshed = scanDatasetDirectory(datasetDir, logger);
      server.setDatasets(refreshed);
      const auto refreshedTransferFunctions = scanTransferFunctionDirectory(datasetDir, logger);
      server.setTransferFunctions(refreshedTransferFunctions);

      for (int i = 0; i < scanIntervalSeconds * 10 && monitorRunning.load(); ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
      }
    }
  });


  logger->info("Type 'q' then Enter to quit.");

  std::string line;
  while (std::getline(std::cin, line)) {
    if (line == "q" || line == "Q") {
      break;
    }
  }

  if (webServer) {
    webServer->stop();
  }
  server.stop();
  monitorRunning = false;
  if (monitorThread.joinable()) {
    monitorThread.join();
  }

  return 0;
}

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
