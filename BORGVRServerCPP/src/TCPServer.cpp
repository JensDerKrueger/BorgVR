#include "TCPServer.h"
#include "BinaryIO.h"
#include "KeyValue.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <chrono>
#include <cstring>
#include <random>
#include <sstream>

static std::string trim(const std::string& s) {
  size_t start = 0;
  while (start < s.size() && std::isspace(static_cast<unsigned char>(s[start]))) start++;
  size_t end = s.size();
  while (end > start && std::isspace(static_cast<unsigned char>(s[end - 1]))) end--;
  return s.substr(start, end - start);
}

static std::vector<std::string> splitWhitespace(const std::string& s) {
  std::vector<std::string> out;
  std::istringstream iss(s);
  std::string token;
  while (iss >> token) {
    out.push_back(token);
  }
  return out;
}

static std::string toUpper(std::string s) {
  std::transform(s.begin(), s.end(), s.begin(),
                 [](unsigned char c) { return static_cast<char>(std::toupper(c)); });
  return s;
}

static std::string trimSecret(const std::string& secret) {
  return trim(secret);
}

static std::vector<uint8_t> randomBytes(size_t count) {
  std::random_device rd;
  std::vector<uint8_t> bytes(count);
  for (size_t i = 0; i < count; ++i) {
    bytes[i] = static_cast<uint8_t>(rd() & 0xff);
  }
  return bytes;
}

static const char kBase64Alphabet[] =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static std::string base64Encode(const std::vector<uint8_t>& data) {
  std::string out;
  out.reserve(((data.size() + 2) / 3) * 4);
  for (size_t i = 0; i < data.size(); i += 3) {
    const uint32_t a = data[i];
    const uint32_t b = (i + 1 < data.size()) ? data[i + 1] : 0;
    const uint32_t c = (i + 2 < data.size()) ? data[i + 2] : 0;
    const uint32_t triple = (a << 16) | (b << 8) | c;
    out.push_back(kBase64Alphabet[(triple >> 18) & 0x3f]);
    out.push_back(kBase64Alphabet[(triple >> 12) & 0x3f]);
    out.push_back(i + 1 < data.size() ? kBase64Alphabet[(triple >> 6) & 0x3f] : '=');
    out.push_back(i + 2 < data.size() ? kBase64Alphabet[triple & 0x3f] : '=');
  }
  return out;
}

static bool base64Decode(const std::string& text, std::vector<uint8_t>& out) {
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

static uint32_t rotr(uint32_t x, uint32_t n) {
  return (x >> n) | (x << (32 - n));
}

static std::array<uint8_t, 32> sha256(const std::vector<uint8_t>& data) {
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

static std::vector<uint8_t> hmacSha256(const std::vector<uint8_t>& key,
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

static std::string authResponse(const std::string& secret,
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

static bool constantTimeEquals(const std::string& a, const std::string& b) {
  size_t diff = a.size() ^ b.size();
  const size_t count = std::min(a.size(), b.size());
  for (size_t i = 0; i < count; ++i) {
    diff |= static_cast<unsigned char>(a[i]) ^ static_cast<unsigned char>(b[i]);
  }
  return diff == 0;
}

TCPServer::TCPServer(uint16_t port,
                     int maxBricksPerGetRequest,
                     std::shared_ptr<Logger> logger,
                     std::string authSecret)
  : port_(port),
    maxBricksPerGetRequest_(maxBricksPerGetRequest),
    authSecret_(trimSecret(authSecret)),
    logger_(std::move(logger)),
    datasets_() {}

TCPServer::~TCPServer() {
  stop();
}

void TCPServer::setDatasets(std::vector<DatasetInfo> datasets) {
  std::lock_guard<std::mutex> lock(datasetsMutex_);

  std::sort(datasets.begin(), datasets.end(),
            [](const DatasetInfo& a, const DatasetInfo& b) {
    return a.id < b.id;
  });

  size_t i = 0;
  size_t j = 0;
  while (i < datasets_.size() && j < datasets.size()) {
    const auto& oldId = datasets_[i].id;
    const auto& newId = datasets[j].id;

    if (oldId == newId) {
      ++i;
      ++j;
    } else if (oldId < newId) {
      logger_->info("Dataset vanished: " + datasets_[i].datasetDescription);
      ++i;
    } else {
      logger_->info("Serving dataset: " + datasets[j].datasetDescription);
      ++j;
    }
  }

  while (i < datasets_.size()) {
    logger_->info("Dataset vanished: " + datasets_[i].datasetDescription);
    ++i;
  }

  while (j < datasets.size()) {
    logger_->info("Serving dataset: " + datasets[j].datasetDescription);
    ++j;
  }


  datasets_ = std::move(datasets);
}

std::vector<DatasetInfo> TCPServer::datasetsSnapshot() const {
  std::lock_guard<std::mutex> lock(datasetsMutex_);
  return datasets_;
}

bool TCPServer::findDatasetById(const std::string& id, DatasetInfo& out) const {
  std::lock_guard<std::mutex> lock(datasetsMutex_);
  auto it = std::find_if(datasets_.begin(), datasets_.end(),
                                                     [&](const DatasetInfo& d) { return d.id == id; });
  if (it == datasets_.end()) return false;
  out = *it;
  return true;
}

bool TCPServer::start() {
  if (running_.load()) return true;
  if (maxBricksPerGetRequest_ <= 0) {
    if (logger_) logger_->error("maxBricksPerGetRequest must be > 0");
    return false;
  }

  if (!listener_.listen(port_)) {
    if (logger_) logger_->error("Failed to listen on port " + std::to_string(port_));
    return false;
  }

  running_.store(true);
  if (logger_) {
    logger_->info(std::string("Server started (protocol ") + kProtocolVersionName +
                 ") on port " + std::to_string(port_));
  }

  acceptThread_ = std::thread([this]() { acceptLoop(); });
  return true;
}

void TCPServer::stop() {
  if (!running_.exchange(false)) {
    return; // already stopped
  }

  listener_.close();

  std::vector<std::shared_ptr<ClientSession>> sessionsCopy;
  {
    std::lock_guard<std::mutex> lock(sessionsMutex_);
    sessionsCopy = sessions_;
  }

  for (auto& s : sessionsCopy) {
    if (s) s->stop();
  }
  for (auto& s : sessionsCopy) {
    if (s) s->join();
  }

  {
    std::lock_guard<std::mutex> lock(sessionsMutex_);
    sessions_.clear();
  }

  if (acceptThread_.joinable()) {
    acceptThread_.join();
  }

  if (logger_) logger_->info("Server stopped");
}

void TCPServer::acceptLoop() {
  while (running_.load()) {
    TcpSocket client = listener_.accept();
    if (!client.valid()) {
      if (!running_.load()) break;
      std::this_thread::sleep_for(std::chrono::milliseconds(20));
      continue;
    }

    auto session = std::make_shared<ClientSession>(*this, std::move(client));
    {
      std::lock_guard<std::mutex> lock(sessionsMutex_);
      sessions_.push_back(session);
      pruneSessionsLocked();
    }
    session->start();
  }
}

void TCPServer::pruneSessionsLocked() {
  // Join and remove sessions whose thread has ended (running_ == false but joinable).
  for (auto it = sessions_.begin(); it != sessions_.end();) {
    auto& s = *it;
    if (!s) {
      it = sessions_.erase(it);
      continue;
    }
    // If session finished naturally, running_ will be false and joinable true.
    // join() is safe and quick once the thread has ended.
    // We can't access session internals here; just keep simple and avoid pruning.
    ++it;
  }
}

// ---------------- ClientSession ----------------

TCPServer::ClientSession::ClientSession(TCPServer& server, TcpSocket socket)
  : server_(server), socket_(std::move(socket)) {}

TCPServer::ClientSession::~ClientSession() {
  stop();
  join();
}

void TCPServer::ClientSession::start() {
  running_.store(true);
  thread_ = std::thread([this]() { run(); });
}

void TCPServer::ClientSession::stop() {
  running_.store(false);
  socket_.shutdownBoth();
  socket_.close();
}

void TCPServer::ClientSession::join() {
  if (thread_.joinable()) {
    thread_.join();
  }
}

bool TCPServer::ClientSession::sendText(const std::string& text) {
  if (!socket_.valid()) return false;
  return socket_.sendAll(text);
}

void TCPServer::ClientSession::sendBinaryResponse(const std::vector<uint8_t>& payload) {
  if (!socket_.valid()) return;

  if (payload.size() > static_cast<size_t>(INT32_MAX)) {
    if (server_.logger_) server_.logger_->error("Binary payload too large for Int32 length prefix.");
    stop();
    return;
  }

  std::vector<uint8_t> msg;
  msg.reserve(4 + payload.size());
  append_i32_le(msg, static_cast<int32_t>(payload.size()));
  msg.insert(msg.end(), payload.begin(), payload.end());

  if (!socket_.sendAll(msg)) {
    if (server_.logger_) server_.logger_->error("Failed to send binary response.");
    stop();
  }
}

bool TCPServer::ClientSession::sendList(const std::vector<std::string>& params) {
  if (!params.empty()) return false;

  const auto datasets = server_.datasetsSnapshot();

  std::ostringstream oss;
  for (size_t i = 0; i < datasets.size(); ++i) {
    const auto& d = datasets[i];
    oss << d.id << " " << d.datasetDescription;
    if (i + 1 < datasets.size()) oss << "\n";
  }
  oss << "\n\n";

  return sendText(oss.str());
}

bool TCPServer::ClientSession::sendInfo(const std::vector<std::string>& params) {
  if (!params.empty()) return false;

  KeyValueBuilder kv;
  kv.set("VERSION", TCPServer::kProtocolVersionName);
  kv.set("MAX_BRICKS_PER_GET_REQUEST", server_.maxBricksPerGetRequest_);
  const std::string info = kv.synthesize() + "\n";

  return sendText(info);
}

bool TCPServer::ClientSession::sendHello(const std::vector<std::string>& params) {
  if (!params.empty()) return false;

  KeyValueBuilder kv;
  kv.set("VERSION", TCPServer::kProtocolVersionName);
  if (server_.authSecret_.empty()) {
    kv.set("AUTH", "NONE");
    authenticated_ = true;
  } else {
    salt_ = randomBytes(16);
    serverNonce_ = randomBytes(32);
    authenticated_ = false;
    kv.set("AUTH", "REQUIRED");
    kv.set("SALT", base64Encode(salt_));
    kv.set("SERVER_NONCE", base64Encode(serverNonce_));
  }
  return sendText(kv.synthesize() + "\n");
}

bool TCPServer::ClientSession::sendAuthResult(const std::string& result) {
  KeyValueBuilder kv;
  kv.set("AUTH", result);
  return sendText(kv.synthesize() + "\n");
}

bool TCPServer::ClientSession::authenticate(const std::vector<std::string>& params) {
  if (server_.authSecret_.empty()) {
    authenticated_ = true;
    return sendAuthResult("OK");
  }
  if (params.size() != 2 || salt_.empty() || serverNonce_.empty()) {
    return sendAuthResult("FAILED");
  }

  std::vector<uint8_t> clientNonce;
  if (!base64Decode(params[0], clientNonce)) {
    return sendAuthResult("FAILED");
  }

  const std::string expected = authResponse(server_.authSecret_, salt_, serverNonce_, clientNonce);
  if (!constantTimeEquals(params[1], expected)) {
    if (server_.logger_) server_.logger_->warning("Client authentication failed.");
    return sendAuthResult("FAILED");
  }

  authenticated_ = true;
  salt_.clear();
  serverNonce_.clear();
  return sendAuthResult("OK");
}

bool TCPServer::ClientSession::commandAllowed() const {
  return server_.authSecret_.empty() || authenticated_;
}

bool TCPServer::ClientSession::openDataset(const std::vector<std::string>& params) {
  if (params.size() != 1) return false;
  const std::string id = params[0];

  DatasetInfo chosen;
  if (!server_.findDatasetById(id, chosen)) {
    if (server_.logger_) server_.logger_->warning("OPEN unknown dataset id: " + id);
    return false;
  }

  // Close previous dataset (if any)
  dataset_.reset();
  brickBuffer_.clear();

  try {
    dataset_ = std::make_unique<BORGVRFileData>(chosen.filename);
    brickBuffer_ = dataset_->allocateBrickBuffer();

    if (server_.logger_) {
      server_.logger_->info("Opened dataset: " + chosen.filename + " (id " + id + ")");
    }

    const auto bytes = dataset_->metadata().toBytes();
    sendBinaryResponse(bytes);
    return true;
  } catch (const std::exception& e) {
    if (server_.logger_) server_.logger_->error(std::string("Failed to open dataset: ") + e.what());
    return false;
  }
}

static bool parseIntStrict(const std::string& s, int& out) {
  if (s.empty()) return false;
  size_t idx = 0;
  try {
    int v = std::stoi(s, &idx, 10);
    if (idx != s.size()) return false;
    out = v;
    return true;
  } catch (...) {
    return false;
  }
}

bool TCPServer::ClientSession::getBricks(const std::vector<std::string>& params) {
  if (params.empty()) return false;
  if (static_cast<int>(params.size()) > server_.maxBricksPerGetRequest_) return false;
  if (!dataset_) return false;

  std::vector<int> indices;
  indices.reserve(params.size());
  for (const auto& p : params) {
    int v = 0;
    if (!parseIntStrict(p, v)) return false;
    indices.push_back(v);
  }

  const auto& md = dataset_->metadata();
  const size_t brickCount = md.brickMetadata().size();
  if (brickCount == 0) return false;

  for (int idx : indices) {
    if (idx < 0 || static_cast<size_t>(idx) >= brickCount) {
      if (server_.logger_) {
        server_.logger_->warning("GETBRICKS index out of range: " + std::to_string(idx) +
                                 " (valid 0.." + std::to_string(brickCount - 1) + ")");
      }
      return false;
    }
  }

  size_t totalSize = 0;
  for (int idx : indices) {
    const auto& bm = md.getBrickMetadata(idx);
    if (bm.size < 0) return false;
    totalSize += static_cast<size_t>(bm.size);
  }

  std::vector<uint8_t> payload;
  payload.reserve(totalSize);

  try {
    for (int idx : indices) {
      const auto& bm = md.getBrickMetadata(idx);
      const size_t sz = static_cast<size_t>(bm.size);
      if (brickBuffer_.size() < sz) {
        // brickBuffer_ is sized for fullBrickSize; raw brick should never exceed that.
        return false;
      }
      dataset_->getRawBrick(bm, brickBuffer_.data(), brickBuffer_.size());
      payload.insert(payload.end(), brickBuffer_.begin(), brickBuffer_.begin() + sz);
    }
  } catch (const std::exception& e) {
    if (server_.logger_) server_.logger_->error(std::string("GETBRICKS failed: ") + e.what());
    return false;
  }

  sendBinaryResponse(payload);
  return true;
}

bool TCPServer::ClientSession::processCommand(const std::string& line) {
  const auto tokens = splitWhitespace(line);
  if (tokens.empty()) return false;

  const std::string cmd = toUpper(tokens[0]);
  std::vector<std::string> params;
  if (tokens.size() > 1) {
    params.assign(tokens.begin() + 1, tokens.end());
  }

  if (cmd == "HELLO") return sendHello(params);
  if (cmd == "AUTH") return authenticate(params);

  if (!commandAllowed()) {
    if (server_.logger_) server_.logger_->warning("Rejecting unauthenticated command.");
    return false;
  }

  if (cmd == "LIST") return sendList(params);
  if (cmd == "INFO") return sendInfo(params);
  if (cmd == "OPEN") return openDataset(params);
  if (cmd == "GETBRICKS") return getBricks(params);

  return false;
}

void TCPServer::ClientSession::run() {

  std::string buffer;
  buffer.reserve(4096);
  constexpr size_t kMaxLineBytes = 8 * 1024;

  uint8_t temp[1024];

  while (running_.load() && server_.running_.load() && socket_.valid()) {
    const int rc = socket_.recvSome(temp, sizeof(temp));
    if (rc < 0) {
      if (server_.logger_) server_.logger_->warning("Client recv error; disconnecting");
      break;
    }
    if (rc == 0) {
      // orderly shutdown
      break;
    }

    buffer.append(reinterpret_cast<const char*>(temp), static_cast<size_t>(rc));
    if (buffer.size() > kMaxLineBytes * 4) {
      if (server_.logger_) server_.logger_->warning("Input buffer too large; disconnecting");
      break;
    }

    for (;;) {
      const auto pos = buffer.find('\n');
      if (pos == std::string::npos) break;

      std::string line = buffer.substr(0, pos);
      buffer.erase(0, pos + 1);

      line = trim(line);
      if (line.empty()) {
        running_.store(false);
        break;
      }
      if (line.size() > kMaxLineBytes) {
        if (server_.logger_) server_.logger_->warning("Command line too long; disconnecting");
        running_.store(false);
        break;
      }

      if (!processCommand(line)) {
        running_.store(false);
        break;
      }
    }
  }

  stop();
  if (server_.logger_) server_.logger_->info("Client disconnected");
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
