#include "Socket.h"

#include <cstring>

#if defined(_WIN32)
  #include <winsock2.h>
  #include <ws2tcpip.h>
  #pragma comment(lib, "Ws2_32.lib")
#else
  #include <arpa/inet.h>
  #include <netinet/in.h>
  #include <sys/socket.h>
  #include <unistd.h>
#endif

SocketSystem::SocketSystem() {
#if defined(_WIN32)
  WSADATA wsa{};
  const int rc = WSAStartup(MAKEWORD(2, 2), &wsa);
  (void)rc;
#endif
}

SocketSystem::~SocketSystem() {
#if defined(_WIN32)
  WSACleanup();
#endif
}

TcpSocket::TcpSocket(SocketHandle s) : sock_(s) {}

TcpSocket::~TcpSocket() {
  close();
}

TcpSocket::TcpSocket(TcpSocket&& other) noexcept : sock_(other.sock_) {
  other.sock_ = kInvalidSocket;
}

TcpSocket& TcpSocket::operator=(TcpSocket&& other) noexcept {
  if (this != &other) {
    close();
    sock_ = other.sock_;
    other.sock_ = kInvalidSocket;
  }
  return *this;
}

bool TcpSocket::valid() const {
#if defined(_WIN32)
  return sock_ != INVALID_SOCKET;
#else
  return sock_ >= 0;
#endif
}

void TcpSocket::close() {
  if (!valid()) return;
#if defined(_WIN32)
  ::closesocket(sock_);
  sock_ = INVALID_SOCKET;
#else
  ::close(sock_);
  sock_ = -1;
#endif
}

void TcpSocket::shutdownBoth() {
  if (!valid()) return;
#if defined(_WIN32)
  ::shutdown(sock_, SD_BOTH);
#else
  ::shutdown(sock_, SHUT_RDWR);
#endif
}

bool TcpSocket::sendAll(const uint8_t* data, size_t size) {
  if (!valid()) return false;
  size_t sent = 0;
  while (sent < size) {
#if defined(_WIN32)
    int rc = ::send(sock_, reinterpret_cast<const char*>(data + sent),
                    static_cast<int>(size - sent), 0);
    if (rc == SOCKET_ERROR) return false;
#else
    ssize_t rc = ::send(sock_, data + sent, size - sent, 0);
    if (rc < 0) return false;
#endif
    if (rc == 0) return false;
    sent += static_cast<size_t>(rc);
  }
  return true;
}

int TcpSocket::recvSome(uint8_t* buffer, size_t capacity) {
  if (!valid()) return -1;
#if defined(_WIN32)
  int rc = ::recv(sock_, reinterpret_cast<char*>(buffer), static_cast<int>(capacity), 0);
  if (rc == SOCKET_ERROR) return -1;
  return rc;
#else
  ssize_t rc = ::recv(sock_, buffer, capacity, 0);
  if (rc < 0) return -1;
  return static_cast<int>(rc);
#endif
}

TcpListener::~TcpListener() {
  close();
}

bool TcpListener::valid() const {
#if defined(_WIN32)
  return sock_ != INVALID_SOCKET;
#else
  return sock_ >= 0;
#endif
}

bool TcpListener::listen(uint16_t port, int backlog) {
  close();
#if defined(__linux__)
  sock_ = ::socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, IPPROTO_TCP);
#else
  sock_ = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
#endif
  if (!valid()) {
    return false;
  }

  int opt = 1;
#if defined(_WIN32)
  ::setsockopt(sock_, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<const char*>(&opt), sizeof(opt));
#else
  ::setsockopt(sock_, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
#endif

  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(port);
  addr.sin_addr.s_addr = htonl(INADDR_ANY);

  if (::bind(sock_, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
    close();
    return false;
  }

  if (::listen(sock_, backlog) != 0) {
    close();
    return false;
  }

  return true;
}

void TcpListener::close() {
  if (!valid()) return;
#if defined(_WIN32)
  ::closesocket(sock_);
  sock_ = INVALID_SOCKET;
#else
  ::close(sock_);
  sock_ = -1;
#endif
}

TcpSocket TcpListener::accept() {
  if (!valid()) return TcpSocket{};
  sockaddr_in clientAddr{};
#if defined(_WIN32)
  int len = sizeof(clientAddr);
  SocketHandle s = ::accept(sock_, reinterpret_cast<sockaddr*>(&clientAddr), &len);
  if (s == INVALID_SOCKET) return TcpSocket{};
#else
  socklen_t len = sizeof(clientAddr);
  SocketHandle s = ::accept(sock_, reinterpret_cast<sockaddr*>(&clientAddr), &len);
  if (s < 0) return TcpSocket{};
#endif
  return TcpSocket{s};
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
