#include "BorgVRAuthCrypto.h"

#include <algorithm>
#include <random>
#include <utility>

namespace BorgVRAuthCrypto {
namespace {

constexpr char kBase64Alphabet[] =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

int base64Value(char character) {
  if (character >= 'A' && character <= 'Z') return character - 'A';
  if (character >= 'a' && character <= 'z') return character - 'a' + 26;
  if (character >= '0' && character <= '9') return character - '0' + 52;
  if (character == '+') return 62;
  if (character == '/') return 63;
  if (character == '=') return -2;
  return -1;
}

uint32_t rotateRight(uint32_t value, uint32_t count) {
  return (value >> count) | (value << (32 - count));
}

}  // namespace

Bytes randomBytes(size_t count) {
  std::random_device randomDevice;
  Bytes bytes(count);
  for (uint8_t& byte : bytes) {
    byte = static_cast<uint8_t>(randomDevice() & 0xff);
  }
  return bytes;
}

std::string base64Encode(const Bytes& data) {
  std::string output;
  output.reserve(((data.size() + 2) / 3) * 4);
  for (size_t index = 0; index < data.size(); index += 3) {
    const uint32_t first = data[index];
    const uint32_t second = index + 1 < data.size() ? data[index + 1] : 0;
    const uint32_t third = index + 2 < data.size() ? data[index + 2] : 0;
    const uint32_t triple = (first << 16) | (second << 8) | third;
    output.push_back(kBase64Alphabet[(triple >> 18) & 0x3f]);
    output.push_back(kBase64Alphabet[(triple >> 12) & 0x3f]);
    output.push_back(index + 1 < data.size()
      ? kBase64Alphabet[(triple >> 6) & 0x3f]
      : '=');
    output.push_back(index + 2 < data.size()
      ? kBase64Alphabet[triple & 0x3f]
      : '=');
  }
  return output;
}

bool base64Decode(const std::string& text, Bytes& output) {
  if (text.size() % 4 != 0) return false;

  Bytes decoded;
  decoded.reserve((text.size() / 4) * 3);
  for (size_t index = 0; index < text.size(); index += 4) {
    const int first = base64Value(text[index]);
    const int second = base64Value(text[index + 1]);
    const int third = base64Value(text[index + 2]);
    const int fourth = base64Value(text[index + 3]);
    const bool isFinalBlock = index + 4 == text.size();

    if (first < 0 || second < 0 || third == -1 || fourth == -1) return false;
    if (third == -2 && (!isFinalBlock || fourth != -2 || (second & 0x0f) != 0)) {
      return false;
    }
    if (third >= 0 && fourth == -2 && (!isFinalBlock || (third & 0x03) != 0)) {
      return false;
    }
    if (third == -2 || fourth == -2) {
      if (!isFinalBlock) return false;
    }

    const uint32_t triple =
      (static_cast<uint32_t>(first) << 18) |
      (static_cast<uint32_t>(second) << 12) |
      (static_cast<uint32_t>(third < 0 ? 0 : third) << 6) |
      static_cast<uint32_t>(fourth < 0 ? 0 : fourth);
    decoded.push_back(static_cast<uint8_t>((triple >> 16) & 0xff));
    if (third != -2) decoded.push_back(static_cast<uint8_t>((triple >> 8) & 0xff));
    if (fourth != -2) decoded.push_back(static_cast<uint8_t>(triple & 0xff));
  }

  output = std::move(decoded);
  return true;
}

Sha256Digest sha256(const Bytes& data) {
  static constexpr uint32_t constants[64] = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
  };

  Bytes message = data;
  const uint64_t bitLength = static_cast<uint64_t>(message.size()) * 8;
  message.push_back(0x80);
  while ((message.size() % 64) != 56) message.push_back(0);
  for (int index = 7; index >= 0; --index) {
    message.push_back(static_cast<uint8_t>((bitLength >> (index * 8)) & 0xff));
  }

  uint32_t hash[8] = {
    0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
    0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19
  };

  for (size_t offset = 0; offset < message.size(); offset += 64) {
    uint32_t words[64];
    for (int index = 0; index < 16; ++index) {
      const size_t byteIndex = offset + static_cast<size_t>(index) * 4;
      words[index] =
        (static_cast<uint32_t>(message[byteIndex]) << 24) |
        (static_cast<uint32_t>(message[byteIndex + 1]) << 16) |
        (static_cast<uint32_t>(message[byteIndex + 2]) << 8) |
        static_cast<uint32_t>(message[byteIndex + 3]);
    }
    for (int index = 16; index < 64; ++index) {
      const uint32_t first = rotateRight(words[index - 15], 7) ^
        rotateRight(words[index - 15], 18) ^ (words[index - 15] >> 3);
      const uint32_t second = rotateRight(words[index - 2], 17) ^
        rotateRight(words[index - 2], 19) ^ (words[index - 2] >> 10);
      words[index] = words[index - 16] + first + words[index - 7] + second;
    }

    uint32_t a = hash[0], b = hash[1], c = hash[2], d = hash[3];
    uint32_t e = hash[4], f = hash[5], g = hash[6], h = hash[7];
    for (int index = 0; index < 64; ++index) {
      const uint32_t first = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25);
      const uint32_t choose = (e & f) ^ ((~e) & g);
      const uint32_t temporaryFirst = h + first + choose + constants[index] + words[index];
      const uint32_t second = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22);
      const uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
      const uint32_t temporarySecond = second + majority;
      h = g;
      g = f;
      f = e;
      e = d + temporaryFirst;
      d = c;
      c = b;
      b = a;
      a = temporaryFirst + temporarySecond;
    }

    hash[0] += a; hash[1] += b; hash[2] += c; hash[3] += d;
    hash[4] += e; hash[5] += f; hash[6] += g; hash[7] += h;
  }

  Sha256Digest digest{};
  for (int index = 0; index < 8; ++index) {
    digest[index * 4] = static_cast<uint8_t>((hash[index] >> 24) & 0xff);
    digest[index * 4 + 1] = static_cast<uint8_t>((hash[index] >> 16) & 0xff);
    digest[index * 4 + 2] = static_cast<uint8_t>((hash[index] >> 8) & 0xff);
    digest[index * 4 + 3] = static_cast<uint8_t>(hash[index] & 0xff);
  }
  return digest;
}

Bytes hmacSha256(const Bytes& key, const Bytes& message) {
  Bytes normalizedKey = key;
  if (normalizedKey.size() > 64) {
    const auto digest = sha256(normalizedKey);
    normalizedKey.assign(digest.begin(), digest.end());
  }
  normalizedKey.resize(64, 0);

  Bytes outerKeyPad(64);
  Bytes innerKeyPad(64);
  for (size_t index = 0; index < 64; ++index) {
    outerKeyPad[index] = normalizedKey[index] ^ 0x5c;
    innerKeyPad[index] = normalizedKey[index] ^ 0x36;
  }

  Bytes inner = innerKeyPad;
  inner.insert(inner.end(), message.begin(), message.end());
  const auto innerDigest = sha256(inner);

  Bytes outer = outerKeyPad;
  outer.insert(outer.end(), innerDigest.begin(), innerDigest.end());
  const auto outerDigest = sha256(outer);
  return Bytes(outerDigest.begin(), outerDigest.end());
}

std::string authResponse(const std::string& secret,
                         const Bytes& salt,
                         const Bytes& serverNonce,
                         const Bytes& clientNonce) {
  Bytes keySeed(secret.begin(), secret.end());
  keySeed.insert(keySeed.end(), salt.begin(), salt.end());
  const auto keyDigest = sha256(keySeed);
  const Bytes key(keyDigest.begin(), keyDigest.end());

  Bytes message = serverNonce;
  message.insert(message.end(), clientNonce.begin(), clientNonce.end());
  return base64Encode(hmacSha256(key, message));
}

bool constantTimeEquals(const std::string& lhs, const std::string& rhs) {
  size_t difference = lhs.size() ^ rhs.size();
  const size_t count = std::max(lhs.size(), rhs.size());
  for (size_t index = 0; index < count; ++index) {
    const auto left = index < lhs.size() ? static_cast<unsigned char>(lhs[index]) : 0;
    const auto right = index < rhs.size() ? static_cast<unsigned char>(rhs[index]) : 0;
    difference |= left ^ right;
  }
  return difference == 0;
}

}  // namespace BorgVRAuthCrypto
