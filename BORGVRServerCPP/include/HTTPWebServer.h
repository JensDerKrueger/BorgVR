#pragma once

#include "Logger.h"
#include "TCPServer.h"

#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <thread>
#include <vector>

class HTTPWebServer {
public:
  HTTPWebServer(uint16_t port,
                TCPServer& datasetServer,
                std::shared_ptr<Logger> logger,
                std::string authSecret = "");

  ~HTTPWebServer();

  HTTPWebServer(const HTTPWebServer&) = delete;
  HTTPWebServer& operator=(const HTTPWebServer&) = delete;

  bool start();
  void stop();

  bool isRunning() const { return running_.load(); }

  struct Request {
    std::string method;
    std::string target;
    std::string version;
    std::string path;
    std::vector<std::pair<std::string, std::string>> headers;
  };

private:
  void acceptLoop();
  void handleClient(TcpSocket socket);

  bool parseRequest(TcpSocket& socket, Request& request) const;
  bool isAuthorized(const Request& request) const;
  bool shouldCloseConnection(const Request& request, int handledRequestCount) const;
  bool routeRequest(TcpSocket& socket, const Request& request, bool closeAfterSend);

  bool sendCatalog(TcpSocket& socket, bool closeAfterSend);
  bool sendTransferFunctionCatalog(TcpSocket& socket, bool closeAfterSend);
  bool sendTransferFunction(TcpSocket& socket, const std::string& id, bool closeAfterSend);
  bool sendDatasetManifest(TcpSocket& socket, const std::string& datasetID, bool closeAfterSend);
  bool sendBrick(TcpSocket& socket, const std::string& datasetID, const std::string& filename, bool closeAfterSend);
  bool sendBrickBatch(TcpSocket& socket, const std::string& datasetID, const std::string& idsText, bool closeAfterSend);
  bool sendStaticFile(TcpSocket& socket, const std::string& requestPath, bool closeAfterSend);

  bool sendResponse(TcpSocket& socket,
                    int status,
                    const std::string& reason,
                    const std::string& contentType,
                    const std::vector<uint8_t>& body,
                    const std::vector<std::pair<std::string, std::string>>& extraHeaders = {},
                    bool closeAfterSend = true) const;
  bool sendChunkedResponse(TcpSocket& socket,
                           int status,
                           const std::string& reason,
                           const std::string& contentType,
                           const std::vector<uint8_t>& body,
                           const std::vector<std::pair<std::string, std::string>>& extraHeaders = {},
                           bool closeAfterSend = true) const;
  bool sendTextResponse(TcpSocket& socket,
                        int status,
                        const std::string& reason,
                        const std::string& contentType,
                        const std::string& body,
                        const std::vector<std::pair<std::string, std::string>>& extraHeaders = {},
                        bool closeAfterSend = true) const;
  bool sendError(TcpSocket& socket, int status, const std::string& reason, const std::string& message, bool closeAfterSend = true) const;
  bool sendUnauthorized(TcpSocket& socket, bool closeAfterSend = true) const;

  uint16_t port_;
  TCPServer& datasetServer_;
  std::shared_ptr<Logger> logger_;
  std::string authSecret_;

  std::atomic<bool> running_{false};
  std::atomic<int> activeHandlers_{0};
  TcpListener listener_;
  std::thread acceptThread_;
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
