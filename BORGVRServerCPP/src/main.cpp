#include "TCPServer.h"
#include "BORGVRMetaData.h"
#include "Logger.h"
#include "Socket.h"

#include <filesystem>
#include <iostream>
#include <memory>
#include <string>
#include <sstream>
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
            << " port maxBricksPerGetRequest datasetDirectory [scanIntervalSeconds]\n";
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
    } catch (...) {
      // Do not report invalid files; this would trigger many warnings
      // when a large file is being copied into the dataset directory.
      // For debugging, this warning may still be useful.
#ifndef NDEBUG
      if (logger) logger->warning("Unable to load file " + filename);
#endif
    }
  }

  return datasets;
}

int main(int argc, char** argv) {
  SocketSystem sockSys;
  auto logger = std::make_shared<Logger>(LogLevel::Info);

  if (argc < 2) {
    printUsage(argv[0]);
    return 1;
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
    }
  }

  auto datasets = scanDatasetDirectory(datasetDir, logger);

  TCPServer server(port, maxBricks, logger);
  server.setDatasets(datasets);
  if (!server.start()) {
    return 2;
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
