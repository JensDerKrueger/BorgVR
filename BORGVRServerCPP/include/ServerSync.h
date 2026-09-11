#pragma once

#include "Logger.h"

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <thread>
#include <unordered_set>
#include <vector>

struct ServerSyncEndpoint {
  std::string address;
  uint16_t port = 0;
  std::string password;
  int intervalSeconds = 300;

  bool usable() const {
    return !address.empty() && port > 0 && intervalSeconds > 0;
  }
};

class ServerSyncManager {
public:
  using IdProvider = std::function<std::unordered_set<std::string>()>;
  using CatalogChangedCallback = std::function<void()>;

  ServerSyncManager(std::string dataDirectory,
                    std::vector<ServerSyncEndpoint> endpoints,
                    IdProvider localDatasetIds,
                    IdProvider localTransferFunctionIds,
                    CatalogChangedCallback onCatalogChanged,
                    std::shared_ptr<Logger> logger);
  ~ServerSyncManager();

  ServerSyncManager(const ServerSyncManager&) = delete;
  ServerSyncManager& operator=(const ServerSyncManager&) = delete;

  void start();
  void stop();

private:
  void run();

  std::string dataDirectory_;
  std::vector<ServerSyncEndpoint> endpoints_;
  IdProvider localDatasetIds_;
  IdProvider localTransferFunctionIds_;
  CatalogChangedCallback onCatalogChanged_;
  std::shared_ptr<Logger> logger_;

  std::atomic<bool> running_{false};
  std::thread thread_;
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
