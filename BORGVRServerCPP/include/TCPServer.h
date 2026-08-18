#pragma once

#include "BORGVRFileData.h"
#include "Logger.h"
#include "Socket.h"

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

struct DatasetInfo {
  std::string id;                 // string id used by protocol
  std::string filename;           // path to .data file
  std::string datasetDescription; // displayed in LIST
};

class TCPServer {
public:
  static constexpr const char* kProtocolVersionName = "2";

  TCPServer(uint16_t port,
            int maxBricksPerGetRequest,
            std::shared_ptr<Logger> logger,
            std::string authSecret = "");

  ~TCPServer();

  TCPServer(const TCPServer&) = delete;
  TCPServer& operator=(const TCPServer&) = delete;

  bool start();
  void stop();

  bool isRunning() const { return running_.load(); }

  void setDatasets(std::vector<DatasetInfo> datasets);
  std::vector<DatasetInfo> datasetsSnapshot() const;
  bool findDatasetById(const std::string& id, DatasetInfo& out) const;

private:
  class ClientSession {
  public:
    ClientSession(TCPServer& server, TcpSocket socket);
    ~ClientSession();

    void start();
    void stop();
    void join();

  private:
    void run();
    bool processCommand(const std::string& line);
    bool sendHello(const std::vector<std::string>& params);
    bool authenticate(const std::vector<std::string>& params);
    bool sendAuthResult(const std::string& result);
    bool commandAllowed() const;
    bool sendList(const std::vector<std::string>& params);
    bool sendInfo(const std::vector<std::string>& params);
    bool openDataset(const std::vector<std::string>& params);
    bool getBricks(const std::vector<std::string>& params);

    void sendBinaryResponse(const std::vector<uint8_t>& payload);
    bool sendText(const std::string& text);

    TCPServer& server_;
    TcpSocket socket_;
    std::thread thread_;
    std::atomic<bool> running_{false};

    // Per-connection dataset state
    std::unique_ptr<BORGVRFileData> dataset_;
    std::vector<uint8_t> brickBuffer_;
    bool authenticated_{false};
    std::vector<uint8_t> salt_;
    std::vector<uint8_t> serverNonce_;
  };

  void acceptLoop();
  void pruneSessionsLocked();

  uint16_t port_;
  int maxBricksPerGetRequest_;
  std::string authSecret_;
  std::shared_ptr<Logger> logger_;
  std::vector<DatasetInfo> datasets_;
  mutable std::mutex datasetsMutex_;

  std::atomic<bool> running_{false};
  TcpListener listener_;
  std::thread acceptThread_;

  std::mutex sessionsMutex_;
  std::vector<std::shared_ptr<ClientSession>> sessions_;
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
