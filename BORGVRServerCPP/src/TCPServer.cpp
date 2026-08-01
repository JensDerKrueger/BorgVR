#include "TCPServer.h"
#include "BinaryIO.h"
#include "KeyValue.h"

#include <algorithm>
#include <cctype>
#include <chrono>
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

TCPServer::TCPServer(uint16_t port,
                     int maxBricksPerGetRequest,
                     std::shared_ptr<Logger> logger)
  : port_(port),
    maxBricksPerGetRequest_(maxBricksPerGetRequest),
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
