#include "BorgVRAuthCrypto.h"

#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

using BorgVRAuthCrypto::Bytes;

template <typename Container>
std::string hexString(const Container& bytes) {
  std::ostringstream stream;
  stream << std::hex << std::setfill('0');
  for (uint8_t byte : bytes) {
    stream << std::setw(2) << static_cast<unsigned int>(byte);
  }
  return stream.str();
}

void require(bool condition, const std::string& message) {
  if (!condition) throw std::runtime_error(message);
}

Bytes bytes(const std::string& text) {
  return Bytes(text.begin(), text.end());
}

void testBase64() {
  const std::vector<std::pair<std::string, std::string>> vectors = {
    {"", ""},
    {"f", "Zg=="},
    {"fo", "Zm8="},
    {"foo", "Zm9v"},
    {"foob", "Zm9vYg=="},
    {"fooba", "Zm9vYmE="},
    {"foobar", "Zm9vYmFy"}
  };

  for (const auto& vector : vectors) {
    const Bytes input = bytes(vector.first);
    require(BorgVRAuthCrypto::base64Encode(input) == vector.second,
            "Base64 encoding failed for " + vector.first);
    Bytes decoded;
    require(BorgVRAuthCrypto::base64Decode(vector.second, decoded),
            "Base64 decoding rejected a valid vector");
    require(decoded == input, "Base64 roundtrip failed for " + vector.first);
  }

  Bytes sentinel = {1, 2, 3};
  for (const std::string& invalid : {
         "A", "A===", "=AAA", "AA=A", "AA==AAAA", "AB==", "AAB=", "AA?="
       }) {
    Bytes output = sentinel;
    require(!BorgVRAuthCrypto::base64Decode(invalid, output),
            "Base64 decoder accepted invalid input: " + invalid);
    require(output == sentinel, "Failed Base64 decoding modified its output");
  }
}

void testSha256() {
  require(
    hexString(BorgVRAuthCrypto::sha256({})) ==
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "SHA-256 empty-input vector failed"
  );
  require(
    hexString(BorgVRAuthCrypto::sha256(bytes("abc"))) ==
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    "SHA-256 abc vector failed"
  );
}

void testHmacSha256() {
  const Bytes key(20, 0x0b);
  require(
    hexString(BorgVRAuthCrypto::hmacSha256(key, bytes("Hi There"))) ==
      "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
    "RFC 4231 HMAC-SHA-256 vector failed"
  );
}

void testAuthenticationResponse() {
  const Bytes salt = {0, 1, 2, 3};
  const Bytes serverNonce = {4, 5, 6, 7};
  const Bytes clientNonce = {8, 9, 10, 11};
  require(
    BorgVRAuthCrypto::authResponse("secret", salt, serverNonce, clientNonce) ==
      "h1NkUZKSs9g96VeYlNou/CpUGgSlUktrUzaXRFT3afY=",
    "Authentication response vector failed"
  );

  require(BorgVRAuthCrypto::constantTimeEquals("response", "response"),
          "Equal authentication responses differ");
  require(!BorgVRAuthCrypto::constantTimeEquals("response", "responze"),
          "Different authentication responses compare equal");
  require(!BorgVRAuthCrypto::constantTimeEquals("response", "response-longer"),
          "Different-length authentication responses compare equal");
  require(BorgVRAuthCrypto::randomBytes(32).size() == 32,
          "Random byte generator returned the wrong size");
}

}  // namespace

int main() {
  testBase64();
  testSha256();
  testHmacSha256();
  testAuthenticationResponse();
  std::cout << "BorgVR authentication crypto tests passed.\n";
  return 0;
}
