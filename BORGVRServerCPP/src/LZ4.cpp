#include "LZ4.h"

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace lz4 {

// This is a small, dependency-free LZ4 *block* decompressor.
// It follows the LZ4 block format described in the LZ4 specification:
// token (litLen/matchLen), literals, 2-byte little-endian offset, match bytes.
// Returns 0 on any bounds/format error.
size_t decompressBlock(const uint8_t* src, size_t srcSize, uint8_t* dst, size_t dstCapacity) {
  if (!src || !dst) return 0;

  const uint8_t* ip = src;
  const uint8_t* iend = src + srcSize;
  uint8_t* op = dst;
  uint8_t* oend = dst + dstCapacity;

  auto readLength = [&](size_t initial) -> size_t {
    size_t len = initial;
    if (initial == 15) {
      while (ip < iend) {
        const uint8_t s = *ip++;
        len += s;
        if (s != 255) break;
      }
    }
    return len;
  };

  while (ip < iend) {
    const uint8_t token = *ip++;

    // Literals
    const size_t litLen = readLength(static_cast<size_t>(token >> 4));
    if (static_cast<size_t>(iend - ip) < litLen) return 0;
    if (static_cast<size_t>(oend - op) < litLen) return 0;

    if (litLen > 0) {
      std::memcpy(op, ip, litLen);
      ip += litLen;
      op += litLen;
    }

    // End of block can occur right after literals.
    if (ip >= iend) break;

    // Match offset
    if (static_cast<size_t>(iend - ip) < 2) return 0;
    const uint16_t offset = static_cast<uint16_t>(ip[0]) | (static_cast<uint16_t>(ip[1]) << 8);
    ip += 2;
    if (offset == 0) return 0;
    if (op - dst < static_cast<ptrdiff_t>(offset)) return 0;

    uint8_t* match = op - offset;

    // Match length
    size_t matchLen = readLength(static_cast<size_t>(token & 0x0F));
    matchLen += 4; // minimum match length
    if (static_cast<size_t>(oend - op) < matchLen) return 0;

    // Copy match (can overlap)
    while (matchLen--) {
      *op++ = *match++;
    }
  }

  return static_cast<size_t>(op - dst);
}

} // namespace lz4

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
