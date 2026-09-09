#include "HTTPWebServer.h"
#include "TCPServer.h"
#include "BORGVRMetaData.h"
#include "Logger.h"
#include "Socket.h"

#include <atomic>
#include <exception>
#include <filesystem>
#include <iostream>
#include <memory>
#include <mutex>
#include <string>
#include <sstream>
#include <thread>
#include <unordered_set>
#include <vector>

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

  auto datasets = scanDatasetDirectory(datasetDir, logger);

  TCPServer server(port, maxBricks, logger, password);
  server.setDatasets(datasets);
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
