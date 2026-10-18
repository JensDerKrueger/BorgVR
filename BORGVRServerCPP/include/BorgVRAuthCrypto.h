#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace BorgVRAuthCrypto {

using Bytes = std::vector<uint8_t>;
using Sha256Digest = std::array<uint8_t, 32>;

Bytes randomBytes(size_t count);

std::string base64Encode(const Bytes& data);
bool base64Decode(const std::string& text, Bytes& output);

Sha256Digest sha256(const Bytes& data);
Bytes hmacSha256(const Bytes& key, const Bytes& message);

std::string authResponse(const std::string& secret,
                         const Bytes& salt,
                         const Bytes& serverNonce,
                         const Bytes& clientNonce);

bool constantTimeEquals(const std::string& lhs, const std::string& rhs);

}  // namespace BorgVRAuthCrypto
