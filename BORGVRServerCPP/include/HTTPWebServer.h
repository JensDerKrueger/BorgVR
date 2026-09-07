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
    std::string path;
    std::vector<std::pair<std::string, std::string>> headers;
  };

private:
  void acceptLoop();
  void handleClient(TcpSocket socket);

  bool parseRequest(TcpSocket& socket, Request& request) const;
  bool isAuthorized(const Request& request) const;
  bool routeRequest(TcpSocket& socket, const Request& request);

  bool sendCatalog(TcpSocket& socket);
  bool sendDatasetManifest(TcpSocket& socket, const std::string& datasetID);
  bool sendBrick(TcpSocket& socket, const std::string& datasetID, const std::string& filename);
  bool sendStaticFile(TcpSocket& socket, const std::string& requestPath);

  bool sendResponse(TcpSocket& socket,
                    int status,
                    const std::string& reason,
                    const std::string& contentType,
                    const std::vector<uint8_t>& body,
                    const std::vector<std::pair<std::string, std::string>>& extraHeaders = {}) const;
  bool sendTextResponse(TcpSocket& socket,
                        int status,
                        const std::string& reason,
                        const std::string& contentType,
                        const std::string& body,
                        const std::vector<std::pair<std::string, std::string>>& extraHeaders = {}) const;
  bool sendError(TcpSocket& socket, int status, const std::string& reason, const std::string& message) const;
  bool sendUnauthorized(TcpSocket& socket) const;

  uint16_t port_;
  TCPServer& datasetServer_;
  std::shared_ptr<Logger> logger_;
  std::string authSecret_;

  std::atomic<bool> running_{false};
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
