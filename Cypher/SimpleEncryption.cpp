#include "SimpleEncryption.h"

#include <array>
#include <algorithm>
#include <cctype>
#include <cstring>
#include <stdexcept>
#include <random>

namespace SimpleEncryption {

  static inline uint32_t loadLe32(const uint8_t* p) noexcept {
    return (uint32_t)p[0]
    | ((uint32_t)p[1] << 8)
    | ((uint32_t)p[2] << 16)
    | ((uint32_t)p[3] << 24);
  }

  static inline void storeLe32(uint8_t* p, uint32_t v) noexcept {
    p[0] = (uint8_t)(v & 0xFFu);
    p[1] = (uint8_t)((v >> 8) & 0xFFu);
    p[2] = (uint8_t)((v >> 16) & 0xFFu);
    p[3] = (uint8_t)((v >> 24) & 0xFFu);
  }

  static inline void storeLe64(uint8_t* p, uint64_t v) noexcept {
    for (int i = 0; i < 8; i++) {
      p[i] = (uint8_t)((v >> (8 * i)) & 0xFFu);
    }
  }

  // Best-effort stack/heap wipe
  static inline void secureZero(void* p, size_t n) noexcept {
    volatile uint8_t* vp = reinterpret_cast<volatile uint8_t*>(p);
    while (n--) { *vp++ = 0; }
  }

  static inline uint8_t hexValue(char c) {
    if (c >= '0' && c <= '9') return (uint8_t)(c - '0');
    if (c >= 'a' && c <= 'f') return (uint8_t)(c - 'a' + 10);
    if (c >= 'A' && c <= 'F') return (uint8_t)(c - 'A' + 10);
    throw std::invalid_argument("Invalid hex character in UUID");
  }

  static inline bool isAsciiHex(char c) noexcept {
    return (c >= '0' && c <= '9') ||
    (c >= 'a' && c <= 'f') ||
    (c >= 'A' && c <= 'F');
  }

  // Parses UUID by taking all ASCII hex digits (ignores '-' etc.), requiring exactly 32 digits.
  static std::array<uint8_t, 16> parseUuidBytes(const std::string& uuid) {
    std::array<uint8_t, 16> out{};
    size_t nibbles = 0;
    uint8_t hi = 0;

    for (char c : uuid) {
      if (!isAsciiHex(c)) {
        continue;
      }
      if (nibbles >= 32) {
        throw std::invalid_argument("UUID must contain exactly 32 hex digits");
      }

      uint8_t v = hexValue(c);
      if ((nibbles & 1u) == 0u) {
        hi = (uint8_t)(v << 4);
      } else {
        out[nibbles / 2] = (uint8_t)(hi | v);
      }
      ++nibbles;
    }

    if (nibbles != 32) {
      throw std::invalid_argument("UUID must contain exactly 32 hex digits");
    }
    return out;
  }

  // ============================================================
  // SHA-256 (minimal, streaming)
  // ============================================================

  struct Sha256 {
    uint64_t totalLen = 0; // bytes of message (excluding padding)
    uint32_t h[8] = {
      0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
      0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u
    };
    uint8_t buffer[64];
    size_t bufferLen = 0;

    static inline uint32_t rotr(uint32_t x, uint32_t n) noexcept { return (x >> n) | (x << (32 - n)); }
    static inline uint32_t ch(uint32_t x, uint32_t y, uint32_t z) noexcept { return (x & y) ^ (~x & z); }
    static inline uint32_t maj(uint32_t x, uint32_t y, uint32_t z) noexcept { return (x & y) ^ (x & z) ^ (y & z); }
    static inline uint32_t bigSigma0(uint32_t x) noexcept { return rotr(x, 2) ^ rotr(x, 13) ^ rotr(x, 22); }
    static inline uint32_t bigSigma1(uint32_t x) noexcept { return rotr(x, 6) ^ rotr(x, 11) ^ rotr(x, 25); }
    static inline uint32_t smallSigma0(uint32_t x) noexcept { return rotr(x, 7) ^ rotr(x, 18) ^ (x >> 3); }
    static inline uint32_t smallSigma1(uint32_t x) noexcept { return rotr(x, 17) ^ rotr(x, 19) ^ (x >> 10); }

    static constexpr uint32_t k[64] = {
      0x428a2f98u,0x71374491u,0xb5c0fbcfu,0xe9b5dba5u,0x3956c25bu,0x59f111f1u,0x923f82a4u,0xab1c5ed5u,
      0xd807aa98u,0x12835b01u,0x243185beu,0x550c7dc3u,0x72be5d74u,0x80deb1feu,0x9bdc06a7u,0xc19bf174u,
      0xe49b69c1u,0xefbe4786u,0x0fc19dc6u,0x240ca1ccu,0x2de92c6fu,0x4a7484aau,0x5cb0a9dcu,0x76f988dau,
      0x983e5152u,0xa831c66du,0xb00327c8u,0xbf597fc7u,0xc6e00bf3u,0xd5a79147u,0x06ca6351u,0x14292967u,
      0x27b70a85u,0x2e1b2138u,0x4d2c6dfcu,0x53380d13u,0x650a7354u,0x766a0abbu,0x81c2c92eu,0x92722c85u,
      0xa2bfe8a1u,0xa81a664bu,0xc24b8b70u,0xc76c51a3u,0xd192e819u,0xd6990624u,0xf40e3585u,0x106aa070u,
      0x19a4c116u,0x1e376c08u,0x2748774cu,0x34b0bcb5u,0x391c0cb3u,0x4ed8aa4au,0x5b9cca4fu,0x682e6ff3u,
      0x748f82eeu,0x78a5636fu,0x84c87814u,0x8cc70208u,0x90befffau,0xa4506cebu,0xbef9a3f7u,0xc67178f2u
    };

    void compress(const uint8_t block[64]) noexcept {
      uint32_t w[64];
      for (int i = 0; i < 16; i++) {
        w[i] = ((uint32_t)block[4*i] << 24)
        | ((uint32_t)block[4*i+1] << 16)
        | ((uint32_t)block[4*i+2] << 8)
        | ((uint32_t)block[4*i+3]);
      }
      for (int i = 16; i < 64; i++) {
        w[i] = smallSigma1(w[i-2]) + w[i-7] + smallSigma0(w[i-15]) + w[i-16];
      }

      uint32_t a=h[0], b=h[1], c=h[2], d=h[3], e=h[4], f=h[5], g=h[6], hh=h[7];

      for (int i = 0; i < 64; i++) {
        uint32_t t1 = hh + bigSigma1(e) + ch(e,f,g) + k[i] + w[i];
        uint32_t t2 = bigSigma0(a) + maj(a,b,c);
        hh = g; g = f; f = e;
        e = d + t1;
        d = c; c = b; b = a;
        a = t1 + t2;
      }

      h[0]+=a; h[1]+=b; h[2]+=c; h[3]+=d;
      h[4]+=e; h[5]+=f; h[6]+=g; h[7]+=hh;

      secureZero(w, sizeof(w));
    }

    void update(const uint8_t* data, size_t len) noexcept {
      totalLen += len;
      while (len > 0) {
        size_t take = std::min(len, sizeof(buffer) - bufferLen);
        std::memcpy(buffer + bufferLen, data, take);
        bufferLen += take;
        data += take;
        len -= take;

        if (bufferLen == 64) {
          compress(buffer);
          bufferLen = 0;
        }
      }
    }

    std::array<uint8_t, 32> finalize() noexcept {
      // Capture original bit-length before padding.
      const uint64_t bitLen = totalLen * 8;

      // Pad: 0x80 then zeros until length field fits at the end.
      uint8_t pad[64] = {0x80};
      const size_t padLen = (bufferLen < 56) ? (56 - bufferLen) : (120 - bufferLen);
      update(pad, padLen);

      // Append big-endian bit length.
      uint8_t lenBe[8];
      for (int i = 0; i < 8; i++) {
        lenBe[i] = (uint8_t)((bitLen >> (56 - 8*i)) & 0xFFu);
      }
      update(lenBe, 8);

      std::array<uint8_t, 32> out{};
      for (int i = 0; i < 8; i++) {
        out[4*i+0] = (uint8_t)((h[i] >> 24) & 0xFFu);
        out[4*i+1] = (uint8_t)((h[i] >> 16) & 0xFFu);
        out[4*i+2] = (uint8_t)((h[i] >> 8) & 0xFFu);
        out[4*i+3] = (uint8_t)(h[i] & 0xFFu);
      }

      secureZero(buffer, sizeof(buffer));
      secureZero(h, sizeof(h));
      bufferLen = 0;
      totalLen = 0;

      return out;
    }
  };

  // ============================================================
  // ChaCha20
  // ============================================================

  static inline uint32_t rotl32(uint32_t x, int n) noexcept {
    return (x << n) | (x >> (32 - n));
  }

  static inline void quarterRound(uint32_t& a, uint32_t& b, uint32_t& c, uint32_t& d) noexcept {
    a += b; d ^= a; d = rotl32(d, 16);
    c += d; b ^= c; b = rotl32(b, 12);
    a += b; d ^= a; d = rotl32(d, 8);
    c += d; b ^= c; b = rotl32(b, 7);
  }

  static void chacha20Block(uint8_t out[64],
                            const uint8_t key[32],
                            uint32_t counter,
                            const uint8_t nonce[12]) noexcept {
    // "expand 32-byte k" in little-endian 32-bit words:
    static constexpr uint32_t sigma32[4] = {
      0x61707865u, 0x3320646eu, 0x79622d32u, 0x6b206574u
    };

    uint32_t state[16];
    state[0] = sigma32[0];
    state[1] = sigma32[1];
    state[2] = sigma32[2];
    state[3] = sigma32[3];

    for (int i = 0; i < 8; i++) {
      state[4 + i] = loadLe32(key + 4*i);
    }

    state[12] = counter;
    state[13] = loadLe32(nonce + 0);
    state[14] = loadLe32(nonce + 4);
    state[15] = loadLe32(nonce + 8);

    uint32_t x[16];
    std::memcpy(x, state, sizeof(x));

    for (int i = 0; i < 10; i++) {
      quarterRound(x[0], x[4], x[8],  x[12]);
      quarterRound(x[1], x[5], x[9],  x[13]);
      quarterRound(x[2], x[6], x[10], x[14]);
      quarterRound(x[3], x[7], x[11], x[15]);

      quarterRound(x[0], x[5], x[10], x[15]);
      quarterRound(x[1], x[6], x[11], x[12]);
      quarterRound(x[2], x[7], x[8],  x[13]);
      quarterRound(x[3], x[4], x[9],  x[14]);
    }

    for (int i = 0; i < 16; i++) {
      x[i] += state[i];
      storeLe32(out + 4*i, x[i]);
    }

    secureZero(state, sizeof(state));
    secureZero(x, sizeof(x));
  }

  static void chacha20XorInplace(uint8_t* data, size_t len,
                                 const uint8_t key[32],
                                 const uint8_t nonce[12],
                                 uint32_t counterStart = 0) {
    if (len == 0) return;

    // Enforce the ChaCha20 32-bit block counter limit: 2^32 blocks of 64 bytes.
    // This prevents counter wrap under the same (key, nonce).
    const uint64_t blocksNeeded = (uint64_t(len) + 63u) / 64u;
    const uint64_t blocksAvail = (uint64_t(1) << 32) - uint64_t(counterStart);
    if (blocksNeeded > blocksAvail) {
      throw std::length_error("ChaCha20 counter would wrap; split into smaller chunks");
    }

    uint8_t block[64];
    uint32_t counter = counterStart;
    size_t offset = 0;

    while (offset < len) {
      chacha20Block(block, key, counter++, nonce);

      size_t take = std::min<size_t>(64, len - offset);
      uint8_t* p = data + offset;

      // XOR using 64-bit chunks where possible (no alignment assumptions via memcpy).
      size_t i = 0;
      for (; i + 8 <= take; i += 8) {
        uint64_t a, b;
        std::memcpy(&a, p + i, 8);
        std::memcpy(&b, block + i, 8);
        a ^= b;
        std::memcpy(p + i, &a, 8);
      }
      for (; i < take; i++) {
        p[i] ^= block[i];
      }

      offset += take;
    }

    secureZero(block, sizeof(block));
  }

  // ============================================================
  // Key + nonce derivation
  // ============================================================

  static std::array<uint8_t, 32> deriveKeySha256(const std::string& passphrase,
                                                 const std::array<uint8_t, 16>& uuidBytes,
                                                 const std::vector<uint8_t>& saltBytes) noexcept {
    // Equivalent to SHA256(passphrase || uuidBytes), but avoids temporary allocations.
    Sha256 s;
    s.update(reinterpret_cast<const uint8_t*>(passphrase.data()), passphrase.size());
    if (!saltBytes.empty()) {
      s.update(saltBytes.data(), saltBytes.size());
    }
    s.update(uuidBytes.data(), uuidBytes.size());
    return s.finalize();
  }

  static std::array<uint8_t, 12> deriveNonceSha256(const std::array<uint8_t, 16>& uuidBytes,
                                                   uint64_t chunkIndex,
                                                   const std::vector<uint8_t>& saltBytes) noexcept {
    // Equivalent to SHA256(uuidBytes || LE64(chunkIndex)), then truncate to 12 bytes.
    uint8_t chunkLe[8];
    storeLe64(chunkLe, chunkIndex);

    Sha256 s;
    s.update(uuidBytes.data(), uuidBytes.size());
    if (!saltBytes.empty()) {
      s.update(saltBytes.data(), saltBytes.size());
    }
    s.update(chunkLe, sizeof(chunkLe));
    auto h = s.finalize();

    std::array<uint8_t, 12> nonce{};
    std::memcpy(nonce.data(), h.data(), nonce.size());

    secureZero(chunkLe, sizeof(chunkLe));
    secureZero(h.data(), h.size());
    return nonce;
  }

  // ============================================================
  // Public API
  // ============================================================

  Context::Context(const std::string& passphrase, const std::string& uuid,
                   const std::vector<uint8_t>& saltBytes) :
    uuidBytes{parseUuidBytes(uuid)},
    saltBytes{saltBytes}
  {
    key = deriveKeySha256(passphrase, uuidBytes, saltBytes);
  }

  Context::~Context() {
    secureZero(key.data(), key.size());
  }

  void cypher(uint8_t* data, size_t len,
              const Context& context,
              uint64_t chunkIndex) {
    if (len == 0) return;
    auto nonce = deriveNonceSha256(context.uuidBytes, chunkIndex, context.saltBytes);
    chacha20XorInplace(data, len, context.key.data(), nonce.data());
    secureZero(nonce.data(), nonce.size());
  }


  std::vector<uint8_t> cypher(const std::vector<uint8_t>& payload,
                              const Context& context,
                              uint64_t chunkIndex) {
    if (payload.empty()) return {};

    std::vector<uint8_t> out = payload;
    cypher(out.data(), out.size(), context, chunkIndex);
    return out;
  }

  std::vector<uint8_t> cypher(const std::vector<uint8_t>& payload,
                              const std::string& passphrase,
                              const std::string& uuid,
                              uint64_t chunkIndex,
                              const std::vector<uint8_t>& saltBytes) {
    if (payload.empty()) {
      return {};
    } else {
      return cypher(payload,Context{passphrase, uuid, saltBytes}, chunkIndex);
    }
  }

  std::vector<uint8_t> generateSaltBytes(size_t byteCount) {
    if (byteCount == 0) {
      return {};
    }

    std::vector<uint8_t> out(byteCount);
    std::random_device rd;

    // Fill using 32-bit draws from std::random_device.
    size_t i = 0;
    while (i < byteCount) {
      const uint32_t r = (uint32_t)rd();
      for (int b = 0; b < 4 && i < byteCount; ++b, ++i) {
        out[i] = (uint8_t)((r >> (8 * b)) & 0xFF);
      }
    }
    return out;
  }

  static inline char b64Char(int v) {
    static constexpr char tbl[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    return tbl[v & 63];
  }

  std::string encodeSaltString(const std::vector<uint8_t>& saltBytes, bool urlSafeBase64) {
    if (saltBytes.empty()) {
      return {};
    }

    std::string out;
    out.reserve(((saltBytes.size() + 2) / 3) * 4);

    size_t i = 0;
    while (i + 3 <= saltBytes.size()) {
      const uint32_t n = (uint32_t(saltBytes[i]) << 16)
      | (uint32_t(saltBytes[i + 1]) << 8)
      | (uint32_t(saltBytes[i + 2]));
      out.push_back(b64Char((n >> 18) & 63));
      out.push_back(b64Char((n >> 12) & 63));
      out.push_back(b64Char((n >> 6) & 63));
      out.push_back(b64Char(n & 63));
      i += 3;
    }

    const size_t rem = saltBytes.size() - i;
    if (rem == 1) {
      const uint32_t n = (uint32_t(saltBytes[i]) << 16);
      out.push_back(b64Char((n >> 18) & 63));
      out.push_back(b64Char((n >> 12) & 63));
      out.push_back('=');
      out.push_back('=');
    } else if (rem == 2) {
      const uint32_t n = (uint32_t(saltBytes[i]) << 16)
      | (uint32_t(saltBytes[i + 1]) << 8);
      out.push_back(b64Char((n >> 18) & 63));
      out.push_back(b64Char((n >> 12) & 63));
      out.push_back(b64Char((n >> 6) & 63));
      out.push_back('=');
    }

    if (urlSafeBase64) {
      for (char& c : out) {
        if (c == '+') c = '-';
        else if (c == '/') c = '_';
      }
      // Strip padding '='
      while (!out.empty() && out.back() == '=') {
        out.pop_back();
      }
    }

    return out;
  }

  static inline int b64Index(char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
  }

  std::vector<uint8_t> decodeSaltString(const std::string& saltString) {
    if (saltString.empty()) {
      return {};
    }

    // Accept Base64URL and standard Base64; normalize to standard.
    std::string s;
    s.reserve(saltString.size() + 4);
    for (char c : saltString) {
      if (c == '-') c = '+';
      else if (c == '_') c = '/';
      // ignore whitespace (tolerant)
      if (c == ' ' || c == '\n' || c == '\r' || c == '\t') continue;
      s.push_back(c);
    }

    // Add padding to multiple of 4 if needed.
    const size_t mod = s.size() % 4;
    if (mod == 1) {
      throw std::invalid_argument("Invalid base64 salt (length mod 4 == 1)");
    } else if (mod != 0) {
      s.append(4 - mod, '=');
    }

    std::vector<uint8_t> out;
    out.reserve((s.size() / 4) * 3);

    for (size_t i = 0; i < s.size(); i += 4) {
      const char c0 = s[i];
      const char c1 = s[i + 1];
      const char c2 = s[i + 2];
      const char c3 = s[i + 3];

      const int v0 = b64Index(c0);
      const int v1 = b64Index(c1);
      if (v0 < 0 || v1 < 0) {
        throw std::invalid_argument("Invalid base64 salt");
      }

      int v2 = -1;
      int v3 = -1;
      if (c2 != '=') {
        v2 = b64Index(c2);
        if (v2 < 0) throw std::invalid_argument("Invalid base64 salt");
      }
      if (c3 != '=') {
        v3 = b64Index(c3);
        if (v3 < 0) throw std::invalid_argument("Invalid base64 salt");
      }

      const uint32_t n = (uint32_t(v0) << 18)
      | (uint32_t(v1) << 12)
      | (uint32_t((v2 < 0 ? 0 : v2)) << 6)
      | (uint32_t((v3 < 0 ? 0 : v3)));

      out.push_back((uint8_t)((n >> 16) & 0xFF));
      if (c2 != '=') out.push_back((uint8_t)((n >> 8) & 0xFF));
      if (c3 != '=') out.push_back((uint8_t)(n & 0xFF));
    }

    return out;
  }

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
