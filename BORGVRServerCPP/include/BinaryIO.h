#pragma once

#include <cstdint>
#include <cstring>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <vector>

// Read little-endian unsigned/signed integers from a byte buffer.
inline uint16_t read_u16_le(const uint8_t* p) {
  return static_cast<uint16_t>(p[0]) | (static_cast<uint16_t>(p[1]) << 8);
}

inline uint32_t read_u32_le(const uint8_t* p) {
  return static_cast<uint32_t>(p[0]) |
         (static_cast<uint32_t>(p[1]) << 8) |
         (static_cast<uint32_t>(p[2]) << 16) |
         (static_cast<uint32_t>(p[3]) << 24);
}

inline uint64_t read_u64_le(const uint8_t* p) {
  return static_cast<uint64_t>(p[0]) |
         (static_cast<uint64_t>(p[1]) << 8) |
         (static_cast<uint64_t>(p[2]) << 16) |
         (static_cast<uint64_t>(p[3]) << 24) |
         (static_cast<uint64_t>(p[4]) << 32) |
         (static_cast<uint64_t>(p[5]) << 40) |
         (static_cast<uint64_t>(p[6]) << 48) |
         (static_cast<uint64_t>(p[7]) << 56);
}

inline int64_t read_i64_le(const uint8_t* p) {
  return static_cast<int64_t>(read_u64_le(p));
}

inline float read_f32_le(const uint8_t* p) {
  const uint32_t bits = read_u32_le(p);
  float f;
  std::memcpy(&f, &bits, sizeof(float));
  return f;
}

inline void append_u32_le(std::vector<uint8_t>& out, uint32_t v) {
  out.push_back(static_cast<uint8_t>(v & 0xFF));
  out.push_back(static_cast<uint8_t>((v >> 8) & 0xFF));
  out.push_back(static_cast<uint8_t>((v >> 16) & 0xFF));
  out.push_back(static_cast<uint8_t>((v >> 24) & 0xFF));
}

inline void append_i32_le(std::vector<uint8_t>& out, int32_t v) {
  append_u32_le(out, static_cast<uint32_t>(v));
}

inline void append_i64_le(std::vector<uint8_t>& out, int64_t v) {
  uint64_t u = static_cast<uint64_t>(v);
  out.push_back(static_cast<uint8_t>(u & 0xFF));
  out.push_back(static_cast<uint8_t>((u >> 8) & 0xFF));
  out.push_back(static_cast<uint8_t>((u >> 16) & 0xFF));
  out.push_back(static_cast<uint8_t>((u >> 24) & 0xFF));
  out.push_back(static_cast<uint8_t>((u >> 32) & 0xFF));
  out.push_back(static_cast<uint8_t>((u >> 40) & 0xFF));
  out.push_back(static_cast<uint8_t>((u >> 48) & 0xFF));
  out.push_back(static_cast<uint8_t>((u >> 56) & 0xFF));
}

inline void append_f32_le(std::vector<uint8_t>& out, float f) {
  uint32_t bits;
  std::memcpy(&bits, &f, sizeof(float));
  append_u32_le(out, bits);
}

inline void append_bool(std::vector<uint8_t>& out, bool b) {
  out.push_back(b ? 1u : 0u);
}

inline void append_bytes(std::vector<uint8_t>& out, const uint8_t* p, size_t n) {
  out.insert(out.end(), p, p + n);
}

inline void append_string(std::vector<uint8_t>& out, const std::string& s) {
  append_i64_le(out, static_cast<int64_t>(s.size()));
  append_bytes(out, reinterpret_cast<const uint8_t*>(s.data()), s.size());
}

class BinaryReader {
public:
  BinaryReader(const uint8_t* data, size_t size) : data_(data), size_(size), off_(0) {}

  size_t offset() const { return off_; }

  void skip(size_t n, const char* context) {
    require(n, context);
    off_ += n;
  }

  uint8_t read_u8(const char* context) {
    require(1, context);
    return data_[off_++];
  }

  int64_t read_i64(const char* context) {
    require(8, context);
    int64_t v = read_i64_le(data_ + off_);
    off_ += 8;
    return v;
  }

  float read_f32(const char* context) {
    require(4, context);
    float f = read_f32_le(data_ + off_);
    off_ += 4;
    return f;
  }

  bool read_bool(const char* context) {
    auto b = read_u8(context);
    return b != 0;
  }

  std::string read_string(const char* context) {
    const int64_t len64 = read_i64((std::string(context) + ".length").c_str());
    if (len64 < 0) {
      throw std::runtime_error(std::string("Invalid string length while reading ") + context);
    }
    const size_t len = static_cast<size_t>(len64);
    require(len, context);
    std::string s(reinterpret_cast<const char*>(data_ + off_), len);
    off_ += len;
    return s;
  }

private:
  void require(size_t n, const char* context) const {
    if (off_ + n > size_) {
      throw std::runtime_error(std::string("Unexpected end of data while reading ") + context);
    }
  }

  const uint8_t* data_;
  size_t size_;
  size_t off_;
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
