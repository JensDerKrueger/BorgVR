#pragma once

#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace SimpleEncryption {

  std::vector<uint8_t> generateSaltBytes(size_t byteCount = 32);
  std::string encodeSaltString(const std::vector<uint8_t>& saltBytes, bool urlSafeBase64 = true);
  std::vector<uint8_t> decodeSaltString(const std::string& saltString);

  class Context {
  public:
    Context(const std::string& passphrase,
            const std::string& uuid,
            const std::vector<uint8_t>& saltBytes);
    ~Context();
    std::array<uint8_t, 16> uuidBytes{};
    std::array<uint8_t, 32> key{};
    std::vector<uint8_t> saltBytes;
  };

  // uses passphrase and uuid
  std::vector<uint8_t> cypher(const std::vector<uint8_t>& payload,
                              const std::string& passphrase,
                              const std::string& uuid,
                              uint64_t chunkIndex,
                              const std::vector<uint8_t>& saltBytes);

  // uses context build from cached context
  std::vector<uint8_t> cypher(const std::vector<uint8_t>& payload,
                              const Context& ctx,
                              uint64_t chunkIndex);

  // in-place cypher using context
  void cypher(uint8_t* data, size_t len,
              const Context& context,
              uint64_t chunkIndex);
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

