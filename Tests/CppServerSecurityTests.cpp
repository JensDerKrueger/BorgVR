#include "BorgVRAuthCrypto.h"
#include "HTTPWebServer.h"
#include "Logger.h"
#include "ProtocolValidation.h"
#include "Socket.h"
#include "TCPServer.h"

#include <chrono>
#include <cstdint>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {

void require(bool condition, const std::string& message) {
  if (!condition) throw std::runtime_error(message);
}

std::string receiveUntil(TcpSocket& socket, const std::string& marker) {
  std::string response;
  uint8_t bytes[2048];
  while (response.find(marker) == std::string::npos) {
    const int count = socket.recvSome(bytes, sizeof(bytes));
    require(count > 0, "Connection closed before the expected response marker");
    response.append(reinterpret_cast<const char*>(bytes), static_cast<size_t>(count));
    require(response.size() <= 1024 * 1024, "Test response exceeded its safety limit");
  }
  return response;
}

std::string receiveToClose(TcpSocket& socket) {
  std::string response;
  uint8_t bytes[4096];
  for (;;) {
    const int count = socket.recvSome(bytes, sizeof(bytes));
    if (count <= 0) break;
    response.append(reinterpret_cast<const char*>(bytes), static_cast<size_t>(count));
    require(response.size() <= 4 * 1024 * 1024, "Test response exceeded its safety limit");
  }
  return response;
}

size_t occurrenceCount(const std::string& text, const std::string& needle) {
  size_t count = 0;
  size_t cursor = 0;
  while ((cursor = text.find(needle, cursor)) != std::string::npos) {
    ++count;
    cursor += needle.size();
  }
  return count;
}

std::unique_ptr<TCPServer> startNativeServer(uint16_t& port,
                                             const std::shared_ptr<Logger>& logger,
                                             const std::string& password) {
  for (uint32_t candidate = 47100; candidate < 47200; ++candidate) {
    auto server = std::make_unique<TCPServer>(
      static_cast<uint16_t>(candidate), 64, logger, password
    );
    if (server->start()) {
      port = static_cast<uint16_t>(candidate);
      return server;
    }
  }
  throw std::runtime_error("Unable to reserve a native test port");
}

std::unique_ptr<HTTPWebServer> startHTTPServer(uint16_t& port,
                                               TCPServer& datasetServer,
                                               const std::shared_ptr<Logger>& logger,
                                               const std::string& password) {
  for (uint32_t candidate = 47200; candidate < 47300; ++candidate) {
    auto server = std::make_unique<HTTPWebServer>(
      static_cast<uint16_t>(candidate), datasetServer, logger, "test", password
    );
    if (server->start()) {
      port = static_cast<uint16_t>(candidate);
      return server;
    }
  }
  throw std::runtime_error("Unable to reserve an HTTP test port");
}

void testProtocolIdentifiers() {
  using namespace BorgVRProtocolValidation;
  require(isCanonicalUUID("59DBB8EB-1674-4DAE-94D3-369E63D5A418"),
          "Valid UUID was rejected");
  require(!isCanonicalUUID("../../outside-directory"),
          "Path traversal text was accepted as a UUID");
  require(!isCanonicalUUID("59DBB8EB-1674-4DAE-94D3-369E63D5A41Z"),
          "Non-hexadecimal UUID was accepted");
  require(isHexIdentifier("0123456789abcdefABCDEF0123456789", 32),
          "Valid transfer-function hash was rejected");
  require(!isHexIdentifier("../0123456789abcdefABCDEF012345", 32),
          "Path traversal text was accepted as a hash");
  require(identifiersEqual("ABCDEF00", "abcdef00"),
          "Identifier comparison should be case-insensitive");
}

void testAuthenticationAttemptLimit(const std::shared_ptr<Logger>& logger) {
  uint16_t port = 0;
  auto server = startNativeServer(port, logger, "correct-password");

  TcpSocket client;
  require(client.connectTo("127.0.0.1", port), "Unable to connect to native test server");
  client.setReceiveTimeoutMilliseconds(2000);
  require(client.sendAll("HELLO\n"), "Unable to send HELLO");
  receiveUntil(client, "\n\n");

  const std::string nonce = BorgVRAuthCrypto::base64Encode(std::vector<uint8_t>(32, 0));
  for (int attempt = 0; attempt < 3; ++attempt) {
    require(client.sendAll("AUTH " + nonce + " invalid-response\n"),
            "Unable to send invalid authentication response");
    const std::string response = receiveUntil(client, "\n\n");
    require(response.find("AUTH FAILED") != std::string::npos,
            "Invalid authentication did not receive AUTH FAILED");
  }

  uint8_t byte = 0;
  const int count = client.recvSome(&byte, 1);
  require(count <= 0, "Connection remained open after three authentication failures");
  client.close();
  server->stop();
}

void testPartialCommandDeadline(const std::shared_ptr<Logger>& logger) {
  uint16_t port = 0;
  auto server = startNativeServer(port, logger, "");

  TcpSocket client;
  require(client.connectTo("127.0.0.1", port), "Unable to connect for deadline test");
  client.setReceiveTimeoutMilliseconds(2000);
  require(client.sendAll("H"), "Unable to send partial command");
  std::this_thread::sleep_for(std::chrono::milliseconds(400));
  client.sendAll("E");
  std::this_thread::sleep_for(std::chrono::milliseconds(50));

  uint8_t byte = 0;
  const int count = client.recvSome(&byte, 1);
  require(count <= 0, "Partial command remained connected beyond its absolute deadline");
  client.close();
  server->stop();
}

std::string sendHTTPRequest(uint16_t port, const std::string& request) {
  TcpSocket client;
  require(client.connectTo("127.0.0.1", port), "Unable to connect to HTTP test server");
  client.setReceiveTimeoutMilliseconds(2000);
  require(client.sendAll(request), "Unable to send HTTP test request");
  const std::string response = receiveToClose(client);
  client.close();
  return response;
}

void testHTTPAuthenticationAttemptLimit(TCPServer& datasetServer,
                                        const std::shared_ptr<Logger>& logger) {
  uint16_t port = 0;
  auto server = startHTTPServer(port, datasetServer, logger, "correct-password");
  const std::string request =
    "GET /web-data/datasets.json HTTP/1.1\r\nHost: localhost\r\n\r\n";
  const std::string response = sendHTTPRequest(port, request + request + request);
  require(occurrenceCount(response, "HTTP/1.1 401 Unauthorized") == 3,
          "HTTP connection was not closed after three authentication failures");
  server->stop();
}

void testHTTPFraming(TCPServer& datasetServer,
                     const std::shared_ptr<Logger>& logger) {
  uint16_t port = 0;
  auto server = startHTTPServer(port, datasetServer, logger, "");

  const std::string contentLengthResponse = sendHTTPRequest(
    port,
    "GET /web-data/datasets.json HTTP/1.1\r\n"
    "Host: localhost\r\nContent-Length: 1\r\n\r\nX"
  );
  require(contentLengthResponse.empty(), "HTTP request with a body was accepted");

  const std::string transferEncodingResponse = sendHTTPRequest(
    port,
    "GET /web-data/datasets.json HTTP/1.1\r\n"
    "Host: localhost\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
  );
  require(transferEncodingResponse.empty(), "Chunked request body was accepted");

  const std::string lineEndingResponse = sendHTTPRequest(
    port,
    "GET /web-data/datasets.json HTTP/1.1\nHost: localhost\n\n"
  );
  require(lineEndingResponse.empty(), "HTTP request with bare-LF framing was accepted");

  const std::string mixedLineEndingResponse = sendHTTPRequest(
    port,
    "GET /web-data/datasets.json HTTP/1.1\nHost: localhost\r\n\r\n"
  );
  require(mixedLineEndingResponse.empty(), "HTTP request with mixed line endings was accepted");

  const std::string duplicateHostResponse = sendHTTPRequest(
    port,
    "GET /web-data/datasets.json HTTP/1.1\r\n"
    "Host: localhost\r\nHost: other\r\n\r\n"
  );
  require(duplicateHostResponse.empty(), "HTTP request with duplicate Host fields was accepted");

  const std::string first =
    "GET /web-data/datasets.json HTTP/1.1\r\nHost: localhost\r\n\r\n";
  const std::string second =
    "GET /web-data/datasets.json HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
  const std::string pipelinedResponse = sendHTTPRequest(port, first + second);
  require(occurrenceCount(pipelinedResponse, "HTTP/1.1 200 OK") == 2,
          "Valid pipelined HTTP requests were not both served");

  server->stop();
}

} // namespace

int main() {
  SocketSystem socketSystem;
  auto logger = std::make_shared<Logger>(LogLevel::Error, false);

  testProtocolIdentifiers();
  testAuthenticationAttemptLimit(logger);
  testPartialCommandDeadline(logger);

  TCPServer catalogOnlyServer(47350, 64, logger);
  testHTTPAuthenticationAttemptLimit(catalogOnlyServer, logger);
  testHTTPFraming(catalogOnlyServer, logger);

  std::cout << "BorgVR C++ server security tests passed.\n";
  return 0;
}
