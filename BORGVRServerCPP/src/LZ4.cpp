#include "LZ4.h"

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

namespace lz4 {

namespace {

constexpr size_t kMinMatch = 4;
constexpr size_t kMaxOffset = 65535;
constexpr size_t kHashBits = 16;
constexpr size_t kHashSize = size_t{1} << kHashBits;

uint32_t read32(const uint8_t* ptr) {
  uint32_t value = 0;
  std::memcpy(&value, ptr, sizeof(value));
  return value;
}

size_t hashSequence(uint32_t sequence) {
  const uint32_t mixed = sequence * 2654435761u;
  return static_cast<size_t>(mixed >> (32 - kHashBits));
}

bool writeLength(uint8_t*& op, uint8_t* oend, size_t length) {
  while (length >= 255) {
    if (op >= oend) return false;
    *op++ = 255;
    length -= 255;
  }
  if (op >= oend) return false;
  *op++ = static_cast<uint8_t>(length);
  return true;
}

bool emitSequence(uint8_t*& op,
                  uint8_t* oend,
                  const uint8_t* literalStart,
                  size_t literalLength,
                  uint16_t matchOffset,
                  size_t matchLength) {
  if (op >= oend) return false;
  uint8_t* token = op++;

  const size_t tokenLiteralLength = literalLength < 15 ? literalLength : 15;
  const size_t encodedMatchLength = matchLength >= kMinMatch ? matchLength - kMinMatch : 0;
  const size_t tokenMatchLength = encodedMatchLength < 15 ? encodedMatchLength : 15;
  *token = static_cast<uint8_t>((tokenLiteralLength << 4) | tokenMatchLength);

  if (literalLength >= 15 && !writeLength(op, oend, literalLength - 15)) {
    return false;
  }
  if (static_cast<size_t>(oend - op) < literalLength) return false;
  if (literalLength > 0) {
    std::memcpy(op, literalStart, literalLength);
    op += literalLength;
  }

  if (matchLength == 0) {
    return true;
  }

  if (static_cast<size_t>(oend - op) < 2) return false;
  *op++ = static_cast<uint8_t>(matchOffset & 0xff);
  *op++ = static_cast<uint8_t>((matchOffset >> 8) & 0xff);

  if (encodedMatchLength >= 15 && !writeLength(op, oend, encodedMatchLength - 15)) {
    return false;
  }
  return true;
}

} // namespace

size_t compressBlockBound(size_t srcSize) {
  return srcSize + (srcSize / 255) + 16;
}

size_t compressBlock(const uint8_t* src, size_t srcSize, uint8_t* dst, size_t dstCapacity) {
  if (!src || !dst) return 0;

  if (dstCapacity < compressBlockBound(srcSize)) {
    return 0;
  }

  const uint8_t* ip = src;
  const uint8_t* anchor = src;
  const uint8_t* const iend = src + srcSize;
  const uint8_t* const matchLimit = srcSize >= kMinMatch ? iend - kMinMatch : src;
  uint8_t* op = dst;
  uint8_t* const oend = dst + dstCapacity;

  std::vector<size_t> hashTable(kHashSize, static_cast<size_t>(-1));

  while (ip <= matchLimit) {
    const size_t hash = hashSequence(read32(ip));
    const size_t refOffset = hashTable[hash];
    hashTable[hash] = static_cast<size_t>(ip - src);

    if (refOffset == static_cast<size_t>(-1) ||
        static_cast<size_t>(ip - src) <= refOffset ||
        static_cast<size_t>(ip - src) - refOffset > kMaxOffset ||
        std::memcmp(src + refOffset, ip, kMinMatch) != 0) {
      ++ip;
      continue;
    }

    const uint8_t* match = src + refOffset;
    const uint8_t* matchStart = ip;
    ip += kMinMatch;
    match += kMinMatch;
    while (ip < iend && *ip == *match) {
      ++ip;
      ++match;
    }

    const size_t literalLength = static_cast<size_t>(matchStart - anchor);
    const size_t matchLength = static_cast<size_t>(ip - matchStart);
    const uint16_t offset = static_cast<uint16_t>(matchStart - (src + refOffset));
    if (!emitSequence(op, oend, anchor, literalLength, offset, matchLength)) {
      return 0;
    }
    anchor = ip;
  }

  const size_t literalLength = static_cast<size_t>(iend - anchor);
  if (!emitSequence(op, oend, anchor, literalLength, 0, 0)) {
    return 0;
  }

  return static_cast<size_t>(op - dst);
}

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
