#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#if defined(_WIN32)
  #include <winsock2.h>
  #include <ws2tcpip.h>
  using SocketHandle = SOCKET;
  constexpr SocketHandle kInvalidSocket = INVALID_SOCKET;
#else
  using SocketHandle = int;
  constexpr SocketHandle kInvalidSocket = -1;
#endif

class SocketSystem {
public:
  SocketSystem();
  ~SocketSystem();

  SocketSystem(const SocketSystem&) = delete;
  SocketSystem& operator=(const SocketSystem&) = delete;
};

class TcpSocket {
public:
  TcpSocket() = default;
  explicit TcpSocket(SocketHandle s);
  ~TcpSocket();

  TcpSocket(const TcpSocket&) = delete;
  TcpSocket& operator=(const TcpSocket&) = delete;

  TcpSocket(TcpSocket&& other) noexcept;
  TcpSocket& operator=(TcpSocket&& other) noexcept;

  bool valid() const;
  SocketHandle handle() const { return sock_; }

  void close();
  void shutdownBoth();

  // Blocking send of all bytes.
  bool sendAll(const uint8_t* data, size_t size);
  bool sendAll(const std::vector<uint8_t>& data) { return sendAll(data.data(), data.size()); }
  bool sendAll(const std::string& s) { return sendAll(reinterpret_cast<const uint8_t*>(s.data()), s.size()); }

  // Blocking recv. Returns:
  // - >0 bytes on success
  // - 0 on orderly shutdown
  // - <0 on error
  int recvSome(uint8_t* buffer, size_t capacity);

private:
  SocketHandle sock_ = kInvalidSocket;
};

class TcpListener {
public:
  TcpListener() = default;
  ~TcpListener();

  TcpListener(const TcpListener&) = delete;
  TcpListener& operator=(const TcpListener&) = delete;

  bool listen(uint16_t port, int backlog = 16);
  void close();

  TcpSocket accept();

  bool valid() const;

private:
  SocketHandle sock_ = kInvalidSocket;
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
