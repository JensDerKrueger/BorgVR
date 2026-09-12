#include "ServerSync.h"

#include "BORGVRMetaData.h"
#include "BinaryIO.h"
#include "Socket.h"
#include "TCPServer.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cctype>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <map>
#include <random>
#include <sstream>
#include <stdexcept>
#include <unordered_map>

namespace {

constexpr size_t kMaxTextResponseBytes = 8 * 1024 * 1024;
constexpr size_t kMaxBinaryResponseBytes = 512 * 1024 * 1024;
constexpr size_t kMaxTransferFunctionEntries = 1u << 16;
constexpr size_t kMaxTransferFunctionDescriptionBytes = 64u * 1024u;
constexpr size_t kMaxTransferFunctionBytes =
  kMaxTransferFunctionEntries * 4u + kMaxTransferFunctionDescriptionBytes;
constexpr size_t kMaxTransferFunctionBytesPerPass = 32u * 1024u * 1024u;

struct RemoteDataset {
  std::string id;
  std::string description;
};

struct RemoteTransferFunction {
  std::string id;
  size_t byteCount = 0;
  std::string description;
};

std::string trim(const std::string& s) {
  size_t start = 0;
  while (start < s.size() && std::isspace(static_cast<unsigned char>(s[start]))) ++start;
  size_t end = s.size();
  while (end > start && std::isspace(static_cast<unsigned char>(s[end - 1]))) --end;
  return s.substr(start, end - start);
}

std::string endpointName(const ServerSyncEndpoint& endpoint) {
  return endpoint.address + ":" + std::to_string(endpoint.port);
}

std::string safeFilename(std::string text, const std::string& fallback) {
  text = trim(text);
  if (text.empty()) text = fallback;
  for (char& c : text) {
    const bool ok = std::isalnum(static_cast<unsigned char>(c)) || c == '-' || c == '_' || c == '.';
    if (!ok) c = '_';
  }
  while (!text.empty() && text.front() == '.') text.erase(text.begin());
  if (text.empty()) text = fallback;
  return text;
}

void writeU64LE(std::ostream& out, uint64_t value) {
  uint8_t bytes[8] = {
    static_cast<uint8_t>(value & 0xff),
    static_cast<uint8_t>((value >> 8) & 0xff),
    static_cast<uint8_t>((value >> 16) & 0xff),
    static_cast<uint8_t>((value >> 24) & 0xff),
    static_cast<uint8_t>((value >> 32) & 0xff),
    static_cast<uint8_t>((value >> 40) & 0xff),
    static_cast<uint8_t>((value >> 48) & 0xff),
    static_cast<uint8_t>((value >> 56) & 0xff)
  };
  out.write(reinterpret_cast<const char*>(bytes), sizeof(bytes));
}

std::vector<uint8_t> randomBytes(size_t count) {
  std::random_device rd;
  std::vector<uint8_t> bytes(count);
  for (size_t i = 0; i < count; ++i) {
    bytes[i] = static_cast<uint8_t>(rd() & 0xff);
  }
  return bytes;
}

const char kBase64Alphabet[] =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

std::string base64Encode(const std::vector<uint8_t>& data) {
  std::string out;
  out.reserve(((data.size() + 2) / 3) * 4);
  for (size_t i = 0; i < data.size(); i += 3) {
    const uint32_t a = data[i];
    const uint32_t b = i + 1 < data.size() ? data[i + 1] : 0;
    const uint32_t c = i + 2 < data.size() ? data[i + 2] : 0;
    const uint32_t triple = (a << 16) | (b << 8) | c;
    out.push_back(kBase64Alphabet[(triple >> 18) & 0x3f]);
    out.push_back(kBase64Alphabet[(triple >> 12) & 0x3f]);
    out.push_back(i + 1 < data.size() ? kBase64Alphabet[(triple >> 6) & 0x3f] : '=');
    out.push_back(i + 2 < data.size() ? kBase64Alphabet[triple & 0x3f] : '=');
  }
  return out;
}

bool base64Decode(const std::string& text, std::vector<uint8_t>& out) {
  auto value = [](char c) -> int {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    if (c == '=') return -2;
    return -1;
  };

  out.clear();
  if (text.empty() || text.size() % 4 != 0) return false;
  for (size_t i = 0; i < text.size(); i += 4) {
    int v0 = value(text[i]);
    int v1 = value(text[i + 1]);
    int v2 = value(text[i + 2]);
    int v3 = value(text[i + 3]);
    if (v0 < 0 || v1 < 0 || v2 == -1 || v3 == -1) return false;
    const uint32_t triple =
      (static_cast<uint32_t>(v0) << 18) |
      (static_cast<uint32_t>(v1) << 12) |
      (static_cast<uint32_t>(v2 < 0 ? 0 : v2) << 6) |
      static_cast<uint32_t>(v3 < 0 ? 0 : v3);
    out.push_back(static_cast<uint8_t>((triple >> 16) & 0xff));
    if (v2 != -2) out.push_back(static_cast<uint8_t>((triple >> 8) & 0xff));
    if (v3 != -2) out.push_back(static_cast<uint8_t>(triple & 0xff));
  }
  return true;
}

uint32_t rotr(uint32_t x, uint32_t n) {
  return (x >> n) | (x << (32 - n));
}

std::array<uint8_t, 32> sha256(const std::vector<uint8_t>& data) {
  static constexpr uint32_t k[64] = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
  };

  std::vector<uint8_t> msg = data;
  const uint64_t bitLength = static_cast<uint64_t>(msg.size()) * 8;
  msg.push_back(0x80);
  while ((msg.size() % 64) != 56) msg.push_back(0);
  for (int i = 7; i >= 0; --i) {
    msg.push_back(static_cast<uint8_t>((bitLength >> (i * 8)) & 0xff));
  }

  uint32_t h[8] = {
    0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
    0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19
  };

  for (size_t offset = 0; offset < msg.size(); offset += 64) {
    uint32_t w[64];
    for (int i = 0; i < 16; ++i) {
      const size_t j = offset + i * 4;
      w[i] = (static_cast<uint32_t>(msg[j]) << 24) |
             (static_cast<uint32_t>(msg[j + 1]) << 16) |
             (static_cast<uint32_t>(msg[j + 2]) << 8) |
             static_cast<uint32_t>(msg[j + 3]);
    }
    for (int i = 16; i < 64; ++i) {
      const uint32_t s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      const uint32_t s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }

    uint32_t a = h[0], b = h[1], c = h[2], d = h[3];
    uint32_t e = h[4], f = h[5], g = h[6], hh = h[7];
    for (int i = 0; i < 64; ++i) {
      const uint32_t s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      const uint32_t ch = (e & f) ^ ((~e) & g);
      const uint32_t temp1 = hh + s1 + ch + k[i] + w[i];
      const uint32_t s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      const uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
      const uint32_t temp2 = s0 + maj;
      hh = g;
      g = f;
      f = e;
      e = d + temp1;
      d = c;
      c = b;
      b = a;
      a = temp1 + temp2;
    }

    h[0] += a; h[1] += b; h[2] += c; h[3] += d;
    h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
  }

  std::array<uint8_t, 32> digest{};
  for (int i = 0; i < 8; ++i) {
    digest[i * 4] = static_cast<uint8_t>((h[i] >> 24) & 0xff);
    digest[i * 4 + 1] = static_cast<uint8_t>((h[i] >> 16) & 0xff);
    digest[i * 4 + 2] = static_cast<uint8_t>((h[i] >> 8) & 0xff);
    digest[i * 4 + 3] = static_cast<uint8_t>(h[i] & 0xff);
  }
  return digest;
}

std::vector<uint8_t> hmacSha256(const std::vector<uint8_t>& key,
                                const std::vector<uint8_t>& message) {
  std::vector<uint8_t> normalizedKey = key;
  if (normalizedKey.size() > 64) {
    auto digest = sha256(normalizedKey);
    normalizedKey.assign(digest.begin(), digest.end());
  }
  normalizedKey.resize(64, 0);

  std::vector<uint8_t> oKeyPad(64);
  std::vector<uint8_t> iKeyPad(64);
  for (size_t i = 0; i < 64; ++i) {
    oKeyPad[i] = normalizedKey[i] ^ 0x5c;
    iKeyPad[i] = normalizedKey[i] ^ 0x36;
  }

  std::vector<uint8_t> inner = iKeyPad;
  inner.insert(inner.end(), message.begin(), message.end());
  auto innerDigest = sha256(inner);

  std::vector<uint8_t> outer = oKeyPad;
  outer.insert(outer.end(), innerDigest.begin(), innerDigest.end());
  auto outerDigest = sha256(outer);
  return std::vector<uint8_t>(outerDigest.begin(), outerDigest.end());
}

std::string authResponse(const std::string& secret,
                         const std::vector<uint8_t>& salt,
                         const std::vector<uint8_t>& serverNonce,
                         const std::vector<uint8_t>& clientNonce) {
  std::vector<uint8_t> keySeed(secret.begin(), secret.end());
  keySeed.insert(keySeed.end(), salt.begin(), salt.end());
  auto keyDigest = sha256(keySeed);
  std::vector<uint8_t> key(keyDigest.begin(), keyDigest.end());

  std::vector<uint8_t> message = serverNonce;
  message.insert(message.end(), clientNonce.begin(), clientNonce.end());
  return base64Encode(hmacSha256(key, message));
}

std::map<std::string, std::string> parseKeyValueResponse(const std::string& text) {
  std::map<std::string, std::string> out;
  std::istringstream lines(text);
  std::string line;
  while (std::getline(lines, line)) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    line = trim(line);
    if (line.empty()) continue;
    const auto space = line.find(' ');
    if (space == std::string::npos) {
      out[line] = "";
    } else {
      out[line.substr(0, space)] = trim(line.substr(space + 1));
    }
  }
  return out;
}

class RemoteClient {
public:
  RemoteClient(ServerSyncEndpoint endpoint, std::shared_ptr<Logger> logger)
    : endpoint_(std::move(endpoint)), logger_(std::move(logger)) {}

  void connectAndAuthenticate() {
    if (!socket_.connectTo(endpoint_.address, endpoint_.port)) {
      throw std::runtime_error("Unable to connect");
    }

    sendCommand("HELLO");
    const auto hello = parseKeyValueResponse(receiveTextResponse());
    auto authIt = hello.find("AUTH");
    if (authIt == hello.end()) {
      throw std::runtime_error("Missing AUTH in HELLO response");
    }

    if (authIt->second == "REQUIRED") {
      std::vector<uint8_t> salt;
      std::vector<uint8_t> serverNonce;
      auto saltIt = hello.find("SALT");
      auto nonceIt = hello.find("SERVER_NONCE");
      if (saltIt == hello.end() || nonceIt == hello.end() ||
          !base64Decode(saltIt->second, salt) ||
          !base64Decode(nonceIt->second, serverNonce)) {
        throw std::runtime_error("Invalid authentication challenge");
      }

      const auto clientNonce = randomBytes(32);
      const auto response = authResponse(trim(endpoint_.password), salt, serverNonce, clientNonce);
      sendCommand("AUTH " + base64Encode(clientNonce) + " " + response);

      const auto auth = parseKeyValueResponse(receiveTextResponse());
      auto resultIt = auth.find("AUTH");
      if (resultIt == auth.end() || resultIt->second != "OK") {
        throw std::runtime_error("Authentication failed");
      }
    } else if (authIt->second != "NONE") {
      throw std::runtime_error("Unsupported authentication mode");
    }

    sendCommand("INFO");
    const auto info = parseKeyValueResponse(receiveTextResponse());
    auto batchIt = info.find("MAX_BRICKS_PER_GET_REQUEST");
    if (batchIt != info.end()) {
      try {
        maxBricksPerRequest_ = std::max(1, std::stoi(batchIt->second));
      } catch (...) {
        maxBricksPerRequest_ = 1;
      }
    }
  }

  int maxBricksPerRequest() const { return maxBricksPerRequest_; }

  std::vector<RemoteDataset> listDatasets() {
    sendCommand("LIST");
    const std::string text = receiveTextResponse();
    std::vector<RemoteDataset> out;
    std::istringstream lines(text);
    std::string line;
    while (std::getline(lines, line)) {
      if (!line.empty() && line.back() == '\r') line.pop_back();
      line = trim(line);
      if (line.empty()) continue;
      const auto space = line.find(' ');
      RemoteDataset dataset;
      dataset.id = space == std::string::npos ? line : line.substr(0, space);
      dataset.description = space == std::string::npos ? "" : trim(line.substr(space + 1));
      if (!dataset.id.empty()) out.push_back(std::move(dataset));
    }
    return out;
  }

  std::vector<RemoteTransferFunction> listTransferFunctions() {
    sendCommand("LISTTF");
    const std::string text = receiveTextResponse();
    std::vector<RemoteTransferFunction> out;
    std::istringstream lines(text);
    std::string line;
    while (std::getline(lines, line)) {
      if (!line.empty() && line.back() == '\r') line.pop_back();
      line = trim(line);
      if (line.empty()) continue;

      std::istringstream iss(line);
      RemoteTransferFunction tf;
      if (!(iss >> tf.id >> tf.byteCount)) continue;
      std::string description;
      std::getline(iss, description);
      tf.description = trim(description);
      if (!tf.id.empty()) out.push_back(std::move(tf));
    }
    return out;
  }

  std::vector<uint8_t> getTransferFunction(const std::string& id) {
    sendCommand("GETTF " + id);
    return receiveBinaryResponse();
  }

  std::vector<uint8_t> openDataset(const std::string& id) {
    sendCommand("OPEN " + id);
    return receiveBinaryResponse();
  }

  std::vector<uint8_t> getBricks(const std::vector<size_t>& indices) {
    if (indices.empty()) return {};
    std::ostringstream command;
    command << "GETBRICKS";
    for (size_t index : indices) {
      command << " " << index;
    }
    sendCommand(command.str());
    return receiveBinaryResponse();
  }

private:
  void sendCommand(const std::string& command) {
    if (!socket_.sendAll(command + "\n")) {
      throw std::runtime_error("Failed to send command");
    }
  }

  std::string receiveTextResponse() {
    std::string buffer;
    uint8_t temp[4096];
    while (buffer.find("\n\n") == std::string::npos) {
      const int rc = socket_.recvSome(temp, sizeof(temp));
      if (rc <= 0) {
        throw std::runtime_error("Connection closed while receiving text response");
      }
      buffer.append(reinterpret_cast<const char*>(temp), static_cast<size_t>(rc));
      if (buffer.size() > kMaxTextResponseBytes) {
        throw std::runtime_error("Text response exceeds safety limit");
      }
    }
    const auto marker = buffer.find("\n\n");
    return buffer.substr(0, marker);
  }

  std::vector<uint8_t> receiveExact(size_t byteCount) {
    std::vector<uint8_t> out(byteCount);
    size_t received = 0;
    while (received < byteCount) {
      const int rc = socket_.recvSome(out.data() + received, byteCount - received);
      if (rc <= 0) {
        throw std::runtime_error("Connection closed while receiving binary response");
      }
      received += static_cast<size_t>(rc);
    }
    return out;
  }

  std::vector<uint8_t> receiveBinaryResponse() {
    const auto header = receiveExact(4);
    const int32_t length = static_cast<int32_t>(read_u32_le(header.data()));
    if (length < 0) {
      throw std::runtime_error("Negative binary response length");
    }
    if (static_cast<size_t>(length) > kMaxBinaryResponseBytes) {
      throw std::runtime_error("Binary response exceeds safety limit");
    }
    return receiveExact(static_cast<size_t>(length));
  }

  ServerSyncEndpoint endpoint_;
  std::shared_ptr<Logger> logger_;
  TcpSocket socket_;
  int maxBricksPerRequest_ = 1;
};

class CacheMap {
public:
  static CacheMap loadOrCreate(const std::filesystem::path& path, size_t count) {
    CacheMap map;
    map.path_ = path;
    map.count_ = count;
    map.bytes_.assign((count + 7) / 8, 0);

    std::ifstream file(path, std::ios::binary);
    if (!file) {
      return map;
    }

    uint8_t countBytes[8]{};
    file.read(reinterpret_cast<char*>(countBytes), sizeof(countBytes));
    if (file.gcount() != static_cast<std::streamsize>(sizeof(countBytes))) {
      return map;
    }
    const uint64_t storedCount = read_u64_le(countBytes);
    if (storedCount != count) {
      return map;
    }

    std::vector<uint8_t> bytes((count + 7) / 8, 0);
    file.read(reinterpret_cast<char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
    if (static_cast<size_t>(file.gcount()) != bytes.size()) {
      return map;
    }
    map.bytes_ = std::move(bytes);
    return map;
  }

  bool isSet(size_t index) const {
    const size_t byteIndex = index / 8;
    const uint8_t bit = static_cast<uint8_t>(0x80u >> (index % 8));
    return byteIndex < bytes_.size() && (bytes_[byteIndex] & bit) != 0;
  }

  void set(size_t index) {
    const size_t byteIndex = index / 8;
    const uint8_t bit = static_cast<uint8_t>(0x80u >> (index % 8));
    if (byteIndex < bytes_.size()) bytes_[byteIndex] |= bit;
  }

  bool complete() const {
    for (size_t i = 0; i < count_; ++i) {
      if (!isSet(i)) return false;
    }
    return true;
  }

  size_t completedCount() const {
    size_t count = 0;
    for (size_t i = 0; i < count_; ++i) {
      if (isSet(i)) ++count;
    }
    return count;
  }

  void save() const {
    const auto tempPath = path_.string() + ".tmp";
    std::ofstream file(tempPath, std::ios::binary | std::ios::trunc);
    if (!file) throw std::runtime_error("Unable to write cache map");
    writeU64LE(file, static_cast<uint64_t>(count_));
    file.write(reinterpret_cast<const char*>(bytes_.data()), static_cast<std::streamsize>(bytes_.size()));
    if (!file) throw std::runtime_error("Unable to finish cache map");
    file.close();
    std::filesystem::rename(tempPath, path_);
  }

private:
  std::filesystem::path path_;
  size_t count_ = 0;
  std::vector<uint8_t> bytes_;
};

uint64_t datasetPayloadSize(const BORGVRMetaData& metadata) {
  uint64_t maxEnd = 8;
  for (const auto& brick : metadata.brickMetadata()) {
    if (brick.offset < 0 || brick.size < 0) {
      throw std::runtime_error("Dataset metadata contains a negative brick offset or size");
    }
    const uint64_t end = static_cast<uint64_t>(brick.offset) + static_cast<uint64_t>(brick.size);
    maxEnd = std::max(maxEnd, end);
  }
  return maxEnd;
}

void ensureIncompleteFile(const std::filesystem::path& path, uint64_t dataSize) {
  bool recreate = true;
  std::error_code ec;
  if (std::filesystem::exists(path, ec) && std::filesystem::file_size(path, ec) == dataSize) {
    recreate = false;
  }
  if (!recreate) return;

  std::ofstream file(path, std::ios::binary | std::ios::trunc);
  if (!file) throw std::runtime_error("Unable to create incomplete dataset file");
  writeU64LE(file, dataSize);
  if (dataSize > 0) {
    file.seekp(static_cast<std::streamoff>(dataSize - 1), std::ios::beg);
    file.put(0);
  }
  if (!file) throw std::runtime_error("Unable to size incomplete dataset file");
}

void writeBytesAt(const std::filesystem::path& path,
                  uint64_t offset,
                  const uint8_t* bytes,
                  size_t byteCount) {
  std::fstream file(path, std::ios::binary | std::ios::in | std::ios::out);
  if (!file) throw std::runtime_error("Unable to open incomplete dataset file for writing");
  file.seekp(static_cast<std::streamoff>(offset), std::ios::beg);
  file.write(reinterpret_cast<const char*>(bytes), static_cast<std::streamsize>(byteCount));
  if (!file) throw std::runtime_error("Unable to write brick data");
}

void finishDatasetFile(const std::filesystem::path& incompletePath,
                       const std::filesystem::path& finalPath,
                       const std::filesystem::path& cacheMapPath,
                       uint64_t dataSize,
                       const std::vector<uint8_t>& metadataBytes) {
  {
    std::fstream file(incompletePath, std::ios::binary | std::ios::in | std::ios::out);
    if (!file) throw std::runtime_error("Unable to open incomplete dataset for finalization");
    file.seekp(static_cast<std::streamoff>(dataSize), std::ios::beg);
    file.write(reinterpret_cast<const char*>(metadataBytes.data()),
               static_cast<std::streamsize>(metadataBytes.size()));
    if (!file) throw std::runtime_error("Unable to append dataset metadata");
  }

  std::error_code ec;
  std::filesystem::remove(finalPath, ec);
  std::filesystem::rename(incompletePath, finalPath);
  std::filesystem::remove(cacheMapPath, ec);
}

bool downloadDatasetFromSource(const ServerSyncEndpoint& endpoint,
                               const RemoteDataset& dataset,
                               const std::string& dataDirectory,
                               std::shared_ptr<Logger> logger,
                               std::atomic<bool>& running) {
  RemoteClient client(endpoint, logger);
  client.connectAndAuthenticate();
  const auto metadataBytes = client.openDataset(dataset.id);

  BORGVRMetaData metadata;
  metadata.parseFromBytes(metadataBytes.data(), metadataBytes.size());
  const auto dataSize = datasetPayloadSize(metadata);
  const auto brickCount = metadata.brickMetadata().size();
  if (brickCount == 0) {
    throw std::runtime_error("Dataset contains no bricks");
  }

  const std::filesystem::path basePath = std::filesystem::path(dataDirectory) / (dataset.id + ".data");
  const std::filesystem::path incompletePath = basePath.string() + ".incomplete";
  const std::filesystem::path cacheMapPath = basePath.string() + ".cachemap";

  ensureIncompleteFile(incompletePath, dataSize);
  auto cacheMap = CacheMap::loadOrCreate(cacheMapPath, brickCount);

  const int remoteBatchLimit = std::max(1, client.maxBricksPerRequest());
  size_t completedBefore = cacheMap.completedCount();
  if (logger) {
    logger->info("Syncing dataset " + metadata.datasetDescription() + " from " +
                 endpointName(endpoint) + " (" + std::to_string(completedBefore) +
                 "/" + std::to_string(brickCount) + " bricks cached)");
  }

  while (running.load() && !cacheMap.complete()) {
    std::vector<size_t> batch;
    batch.reserve(static_cast<size_t>(remoteBatchLimit));

    for (size_t offset = 0; offset < brickCount && batch.size() < static_cast<size_t>(remoteBatchLimit); ++offset) {
      const size_t index = brickCount - 1 - offset;
      if (!cacheMap.isSet(index)) {
        batch.push_back(index);
      }
    }

    if (batch.empty()) break;

    const auto payload = client.getBricks(batch);
    size_t cursor = 0;
    for (size_t index : batch) {
      const auto& brick = metadata.brickMetadata().at(index);
      const size_t brickSize = static_cast<size_t>(brick.size);
      if (cursor + brickSize > payload.size()) {
        throw std::runtime_error("GETBRICKS response ended before all requested bricks were received");
      }
      writeBytesAt(incompletePath,
                   static_cast<uint64_t>(brick.offset),
                   payload.data() + cursor,
                   brickSize);
      cursor += brickSize;
      cacheMap.set(index);
    }
    if (cursor != payload.size()) {
      throw std::runtime_error("GETBRICKS response contains unexpected trailing bytes");
    }
    cacheMap.save();

    const size_t completed = cacheMap.completedCount();
    if (logger && (completed == brickCount || completed >= completedBefore + 512)) {
      completedBefore = completed;
      const double percent = 100.0 * static_cast<double>(completed) / static_cast<double>(brickCount);
      std::ostringstream oss;
      oss << "Dataset sync progress " << metadata.datasetDescription() << ": "
          << completed << "/" << brickCount << " bricks ("
          << std::fixed << std::setprecision(1) << percent << "%)";
      logger->info(oss.str());
    }
  }

  if (!running.load()) return false;
  if (!cacheMap.complete()) return false;

  finishDatasetFile(incompletePath, basePath, cacheMapPath, dataSize, metadataBytes);
  if (logger) {
    logger->info("Finished syncing dataset " + metadata.datasetDescription());
  }
  return true;
}

bool syncTransferFunction(const ServerSyncEndpoint& endpoint,
                          const RemoteTransferFunction& tf,
                          const std::string& dataDirectory,
                          std::shared_ptr<Logger> logger) {
  RemoteClient client(endpoint, logger);
  client.connectAndAuthenticate();
  const auto payload = client.getTransferFunction(tf.id);
  if (payload.empty()) {
    throw std::runtime_error("Transfer function payload is empty");
  }

  const std::string name = safeFilename(tf.description, tf.id);
  std::filesystem::path path = std::filesystem::path(dataDirectory) / (name + ".tf1d");
  if (std::filesystem::exists(path)) {
    path = std::filesystem::path(dataDirectory) / (tf.id + ".tf1d");
  }

  std::ofstream file(path, std::ios::binary | std::ios::trunc);
  if (!file) throw std::runtime_error("Unable to write transfer function");
  file.write(reinterpret_cast<const char*>(payload.data()), static_cast<std::streamsize>(payload.size()));
  if (!file) throw std::runtime_error("Unable to finish transfer function");

  if (logger) {
    logger->info("Synced transfer function " + (tf.description.empty() ? tf.id : tf.description) +
                 " from " + endpointName(endpoint));
  }
  return true;
}

struct CatalogSnapshot {
  ServerSyncEndpoint endpoint;
  std::vector<RemoteDataset> datasets;
  std::vector<RemoteTransferFunction> transferFunctions;
};

} // namespace

ServerSyncManager::ServerSyncManager(std::string dataDirectory,
                                     std::vector<ServerSyncEndpoint> endpoints,
                                     IdProvider localDatasetIds,
                                     IdProvider localTransferFunctionIds,
                                     CatalogChangedCallback onCatalogChanged,
                                     std::shared_ptr<Logger> logger)
  : dataDirectory_(std::move(dataDirectory)),
    endpoints_(std::move(endpoints)),
    localDatasetIds_(std::move(localDatasetIds)),
    localTransferFunctionIds_(std::move(localTransferFunctionIds)),
    onCatalogChanged_(std::move(onCatalogChanged)),
    logger_(std::move(logger)) {}

ServerSyncManager::~ServerSyncManager() {
  stop();
}

void ServerSyncManager::start() {
  if (running_.exchange(true)) return;
  thread_ = std::thread([this]() { run(); });
}

void ServerSyncManager::stop() {
  if (!running_.exchange(false)) return;
  if (thread_.joinable()) {
    thread_.join();
  }
}

void ServerSyncManager::run() {
  if (logger_) {
    logger_->info("Server sync manager started with " + std::to_string(endpoints_.size()) + " endpoint(s)");
  }

  std::vector<std::chrono::steady_clock::time_point> nextCheck(endpoints_.size(),
                                                                std::chrono::steady_clock::now());

  while (running_.load()) {
    const auto now = std::chrono::steady_clock::now();
    std::vector<CatalogSnapshot> snapshots;

    for (size_t i = 0; i < endpoints_.size() && running_.load(); ++i) {
      const auto& endpoint = endpoints_[i];
      if (!endpoint.usable() || now < nextCheck[i]) continue;
      nextCheck[i] = now + std::chrono::seconds(endpoint.intervalSeconds);

      try {
        RemoteClient client(endpoint, logger_);
        client.connectAndAuthenticate();
        CatalogSnapshot snapshot;
        snapshot.endpoint = endpoint;
        snapshot.datasets = client.listDatasets();
        snapshot.transferFunctions = client.listTransferFunctions();
        snapshots.push_back(std::move(snapshot));
      } catch (const std::exception& e) {
        if (logger_) {
          logger_->warning("Server sync catalog request failed for " + endpointName(endpoint) + ": " + e.what());
        }
      }
    }

    if (!snapshots.empty()) {
      bool catalogChanged = false;

      std::unordered_set<std::string> localTfIds =
        localTransferFunctionIds_ ? localTransferFunctionIds_() : std::unordered_set<std::string>{};
      size_t transferredTfBytes = 0;
      for (const auto& snapshot : snapshots) {
        for (const auto& tf : snapshot.transferFunctions) {
          if (!running_.load()) break;
          if (localTfIds.find(tf.id) != localTfIds.end()) continue;
          if (tf.byteCount > kMaxTransferFunctionBytes ||
              transferredTfBytes + tf.byteCount > kMaxTransferFunctionBytesPerPass) continue;

          try {
            if (syncTransferFunction(snapshot.endpoint, tf, dataDirectory_, logger_)) {
              localTfIds.insert(tf.id);
              transferredTfBytes += tf.byteCount;
              catalogChanged = true;
            }
          } catch (const std::exception& e) {
            if (logger_) {
              logger_->warning("Transfer function sync failed for " + tf.id + " from " +
                               endpointName(snapshot.endpoint) + ": " + e.what());
            }
          }
        }
      }

      std::unordered_set<std::string> localDatasetIds =
        localDatasetIds_ ? localDatasetIds_() : std::unordered_set<std::string>{};
      std::unordered_map<std::string, std::vector<std::pair<ServerSyncEndpoint, RemoteDataset>>> sourcesByDataset;
      for (const auto& snapshot : snapshots) {
        for (const auto& dataset : snapshot.datasets) {
          if (localDatasetIds.find(dataset.id) == localDatasetIds.end()) {
            sourcesByDataset[dataset.id].push_back({snapshot.endpoint, dataset});
          }
        }
      }

      for (const auto& entry : sourcesByDataset) {
        if (!running_.load()) break;
        if (localDatasetIds.find(entry.first) != localDatasetIds.end()) continue;

        bool synced = false;
        for (const auto& source : entry.second) {
          if (!running_.load()) break;
          try {
            synced = downloadDatasetFromSource(source.first, source.second, dataDirectory_, logger_, running_);
            if (synced) break;
          } catch (const std::exception& e) {
            if (logger_) {
              logger_->warning("Dataset sync failed for " + entry.first + " from " +
                               endpointName(source.first) + ": " + e.what());
            }
          }
        }

        if (synced) {
          localDatasetIds.insert(entry.first);
          catalogChanged = true;
        }
      }

      if (catalogChanged && onCatalogChanged_) {
        onCatalogChanged_();
      }
    }

    for (int i = 0; i < 10 && running_.load(); ++i) {
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
  }

  if (logger_) {
    logger_->info("Server sync manager stopped");
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
