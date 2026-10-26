#include "TCPServer.h"
#include "BinaryIO.h"
#include "BorgVRAuthCrypto.h"
#include "KeyValue.h"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstring>
#include <fstream>
#include <sstream>

namespace {

constexpr size_t kMaxActiveSessions = 128;
constexpr int kMaximumAuthenticationAttempts = 3;

#ifndef BORGVR_PARTIAL_INPUT_TIMEOUT_MS
#define BORGVR_PARTIAL_INPUT_TIMEOUT_MS 30000
#endif

#ifndef BORGVR_AUTHENTICATION_TIMEOUT_MS
#define BORGVR_AUTHENTICATION_TIMEOUT_MS 30000
#endif

}

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

TCPServer::TCPServer(uint16_t port,
                     int maxBricksPerGetRequest,
                     std::shared_ptr<Logger> logger,
                     std::string authSecret)
  : port_(port),
    maxBricksPerGetRequest_(maxBricksPerGetRequest),
	    authSecret_(trimSecret(authSecret)),
	    logger_(std::move(logger)),
	    datasets_(),
	    transferFunctions_() {}

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

void TCPServer::setTransferFunctions(std::vector<TransferFunctionInfo> transferFunctions) {
  std::lock_guard<std::mutex> lock(datasetsMutex_);

  std::sort(transferFunctions.begin(), transferFunctions.end(),
            [](const TransferFunctionInfo& a, const TransferFunctionInfo& b) {
    return a.id < b.id;
  });

  transferFunctions_ = std::move(transferFunctions);
}

std::vector<TransferFunctionInfo> TCPServer::transferFunctionsSnapshot() const {
  std::lock_guard<std::mutex> lock(datasetsMutex_);
  return transferFunctions_;
}

bool TCPServer::findTransferFunctionById(const std::string& id, TransferFunctionInfo& out) const {
  std::lock_guard<std::mutex> lock(datasetsMutex_);
  auto it = std::find_if(transferFunctions_.begin(), transferFunctions_.end(),
                         [&](const TransferFunctionInfo& tf) { return tf.id == id; });
  if (it == transferFunctions_.end()) return false;
  out = *it;
  return true;
}

void TCPServer::setMarkerFiles(std::vector<MarkerFileInfo> markerFiles) {
  std::lock_guard<std::mutex> lock(datasetsMutex_);
  std::sort(markerFiles.begin(), markerFiles.end(),
            [](const MarkerFileInfo& a, const MarkerFileInfo& b) { return a.id < b.id; });
  markerFiles_ = std::move(markerFiles);
}

std::vector<MarkerFileInfo> TCPServer::markerFilesSnapshot() const {
  std::lock_guard<std::mutex> lock(datasetsMutex_);
  return markerFiles_;
}

bool TCPServer::findMarkerFileById(const std::string& id, MarkerFileInfo& out) const {
  std::lock_guard<std::mutex> lock(datasetsMutex_);
  auto it = std::find_if(markerFiles_.begin(), markerFiles_.end(),
                         [&](const MarkerFileInfo& marker) { return marker.id == id; });
  if (it == markerFiles_.end()) return false;
  out = *it;
  return true;
}

void TCPServer::setMeasurementFiles(std::vector<MeasurementFileInfo> measurementFiles) {
  std::lock_guard<std::mutex> lock(datasetsMutex_);
  std::sort(measurementFiles.begin(), measurementFiles.end(),
            [](const MeasurementFileInfo& a, const MeasurementFileInfo& b) {
    return a.id < b.id;
  });
  measurementFiles_ = std::move(measurementFiles);
}

std::vector<MeasurementFileInfo> TCPServer::measurementFilesSnapshot() const {
  std::lock_guard<std::mutex> lock(datasetsMutex_);
  return measurementFiles_;
}

bool TCPServer::findMeasurementFileById(const std::string& id,
                                        MeasurementFileInfo& out) const {
  std::lock_guard<std::mutex> lock(datasetsMutex_);
  auto it = std::find_if(measurementFiles_.begin(), measurementFiles_.end(),
                         [&](const MeasurementFileInfo& measurement) {
    return measurement.id == id;
  });
  if (it == measurementFiles_.end()) return false;
  out = *it;
  return true;
}

void TCPServer::setMeshFiles(std::vector<MeshFileInfo> meshFiles) {
  std::lock_guard<std::mutex> lock(datasetsMutex_);
  std::sort(meshFiles.begin(), meshFiles.end(),
            [](const MeshFileInfo& a, const MeshFileInfo& b) { return a.id < b.id; });
  meshFiles_ = std::move(meshFiles);
}

std::vector<MeshFileInfo> TCPServer::meshFilesSnapshot() const {
  std::lock_guard<std::mutex> lock(datasetsMutex_);
  return meshFiles_;
}

bool TCPServer::findMeshFileById(const std::string& id, MeshFileInfo& out) const {
  const std::string normalizedId = toUpper(id);
  std::lock_guard<std::mutex> lock(datasetsMutex_);
  const auto it = std::find_if(meshFiles_.begin(), meshFiles_.end(),
                               [&](const MeshFileInfo& mesh) {
                                 return toUpper(mesh.id) == normalizedId;
                               });
  if (it == meshFiles_.end()) return false;
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

    {
      std::lock_guard<std::mutex> lock(sessionsMutex_);
      pruneSessionsLocked();
      if (sessions_.size() >= kMaxActiveSessions) {
        if (logger_) {
          logger_->warning(
            "[client " + client.peerAddress() + "] Connection limit reached; rejecting client"
          );
        }
        continue;
      }
    }

    auto session = std::make_shared<ClientSession>(*this, std::move(client));
    session->start();
    {
      std::lock_guard<std::mutex> lock(sessionsMutex_);
      sessions_.push_back(session);
    }
  }
}

void TCPServer::pruneSessionsLocked() {
  for (auto it = sessions_.begin(); it != sessions_.end();) {
    auto& s = *it;
    if (!s) {
      it = sessions_.erase(it);
      continue;
    }

    if (!s->isRunning()) {
      s->join();
      it = sessions_.erase(it);
      continue;
    }

    ++it;
  }
}

// ---------------- ClientSession ----------------

TCPServer::ClientSession::ClientSession(TCPServer& server, TcpSocket socket)
  : server_(server), socket_(std::move(socket)), clientAddress_(socket_.peerAddress()) {}

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

bool TCPServer::ClientSession::isRunning() const {
  return running_.load();
}

bool TCPServer::ClientSession::sendText(const std::string& text) {
  if (!socket_.valid()) return false;
  return socket_.sendAll(text);
}

std::string TCPServer::ClientSession::clientLogMessage(const std::string& message) const {
  return "[client " + clientAddress_ + "] " + message;
}

void TCPServer::ClientSession::sendBinaryResponse(const std::vector<uint8_t>& payload) {
  if (!socket_.valid()) return;

  if (payload.size() > static_cast<size_t>(INT32_MAX)) {
    if (server_.logger_) {
      server_.logger_->error(clientLogMessage("Binary payload too large for Int32 length prefix."));
    }
    stop();
    return;
  }

  std::vector<uint8_t> header;
  header.reserve(4);
  append_i32_le(header, static_cast<int32_t>(payload.size()));

  if (!socket_.sendAll(header) || !socket_.sendAll(payload)) {
    if (server_.logger_) server_.logger_->error(clientLogMessage("Failed to send binary response."));
    stop();
  }
}

static std::string protocolLineText(std::string text);

bool TCPServer::ClientSession::sendList(const std::vector<std::string>& params) {
  if (!params.empty()) return false;

  const auto datasets = server_.datasetsSnapshot();

  std::ostringstream oss;
  for (size_t i = 0; i < datasets.size(); ++i) {
    const auto& d = datasets[i];
    oss << d.id << " " << protocolLineText(d.datasetDescription);
    if (i + 1 < datasets.size()) oss << "\n";
  }
  oss << "\n\n";

  return sendText(oss.str());
}

static std::string protocolLineText(std::string text) {
  for (char& c : text) {
    if (c == '\r' || c == '\n' || c == '\t') {
      c = ' ';
    }
  }
  return text;
}

bool TCPServer::ClientSession::sendTransferFunctionList(const std::vector<std::string>& params) {
  if (!params.empty()) return false;

  const auto transferFunctions = server_.transferFunctionsSnapshot();

  std::ostringstream oss;
  for (size_t i = 0; i < transferFunctions.size(); ++i) {
    const auto& tf = transferFunctions[i];
    oss << tf.id << " " << tf.byteCount << " " << protocolLineText(tf.transferFunctionDescription);
    if (i + 1 < transferFunctions.size()) oss << "\n";
  }
  oss << "\n\n";

  return sendText(oss.str());
}

bool TCPServer::ClientSession::sendMarkerFileList(const std::vector<std::string>& params) {
  if (!params.empty()) return false;
  const auto markerFiles = server_.markerFilesSnapshot();
  std::ostringstream oss;
  for (size_t i = 0; i < markerFiles.size(); ++i) {
    const auto& marker = markerFiles[i];
    oss << marker.id << " " << marker.byteCount << " " << marker.datasetId << " "
        << protocolLineText(marker.markerDescription);
    if (i + 1 < markerFiles.size()) oss << "\n";
  }
  oss << "\n\n";
  return sendText(oss.str());
}

bool TCPServer::ClientSession::sendMeshFileList(const std::vector<std::string>& params) {
  if (!params.empty()) return false;
  const auto meshes = server_.meshFilesSnapshot();
  std::ostringstream oss;
  for (size_t i = 0; i < meshes.size(); ++i) {
    const auto& mesh = meshes[i];
    oss << mesh.id << " " << mesh.byteCount << " " << protocolLineText(mesh.name);
    if (i + 1 < meshes.size()) oss << "\n";
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
    salt_ = BorgVRAuthCrypto::randomBytes(16);
    serverNonce_ = BorgVRAuthCrypto::randomBytes(32);
    authenticated_ = false;
    kv.set("AUTH", "REQUIRED");
    kv.set("SALT", BorgVRAuthCrypto::base64Encode(salt_));
    kv.set("SERVER_NONCE", BorgVRAuthCrypto::base64Encode(serverNonce_));
  }
  return sendText(kv.synthesize() + "\n");
}

bool TCPServer::ClientSession::sendAuthResult(const std::string& result) {
  KeyValueBuilder kv;
  kv.set("AUTH", result);
  return sendText(kv.synthesize() + "\n");
}

bool TCPServer::ClientSession::authenticate(const std::vector<std::string>& params) {
  const auto rejectAuthentication = [&]() {
    ++failedAuthenticationAttempts_;
    const int delayMilliseconds = 200 << std::min(failedAuthenticationAttempts_ - 1, 2);
    std::this_thread::sleep_for(std::chrono::milliseconds(delayMilliseconds));
    const bool sent = sendAuthResult("FAILED");
    if (failedAuthenticationAttempts_ >= kMaximumAuthenticationAttempts) {
      running_.store(false);
    }
    return sent;
  };

  if (server_.authSecret_.empty()) {
    authenticated_ = true;
    failedAuthenticationAttempts_ = 0;
    return sendAuthResult("OK");
  }
  if (params.size() != 2 || salt_.empty() || serverNonce_.empty()) {
    return rejectAuthentication();
  }

  std::vector<uint8_t> clientNonce;
  if (!BorgVRAuthCrypto::base64Decode(params[0], clientNonce) ||
      clientNonce.size() != 32) {
    return rejectAuthentication();
  }

  const std::string expected = BorgVRAuthCrypto::authResponse(
    server_.authSecret_, salt_, serverNonce_, clientNonce
  );
  if (!BorgVRAuthCrypto::constantTimeEquals(params[1], expected)) {
    if (server_.logger_) server_.logger_->warning(clientLogMessage("Client authentication failed."));
    return rejectAuthentication();
  }

  authenticated_ = true;
  failedAuthenticationAttempts_ = 0;
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
    if (server_.logger_) {
      server_.logger_->warning(clientLogMessage("OPEN received an invalid dataset id."));
    }
    return false;
  }

  // Close previous dataset (if any)
  dataset_.reset();
  brickBuffer_.clear();

  try {
    dataset_ = std::make_unique<BORGVRFileData>(chosen.filename);
    brickBuffer_ = dataset_->allocateBrickBuffer();

    if (server_.logger_) {
      server_.logger_->info(
        clientLogMessage("Opened dataset: " + chosen.filename + " (id " + chosen.id + ")")
      );
    }

    const auto bytes = dataset_->metadata().toBytes();
    sendBinaryResponse(bytes);
    return true;
  } catch (const std::exception& e) {
    if (server_.logger_) {
      server_.logger_->error(clientLogMessage(std::string("Failed to open dataset: ") + e.what()));
    }
    return false;
  }
}

bool TCPServer::ClientSession::getTransferFunction(const std::vector<std::string>& params) {
  if (params.size() != 1) return false;

  TransferFunctionInfo chosen;
  if (!server_.findTransferFunctionById(params[0], chosen)) {
    if (server_.logger_) {
      server_.logger_->warning(clientLogMessage("GETTF received an invalid transfer function id."));
    }
    return false;
  }

  std::ifstream file(chosen.filename, std::ios::binary);
  if (!file) {
    if (server_.logger_) {
      server_.logger_->error(clientLogMessage("Failed to open transfer function: " + chosen.filename));
    }
    return false;
  }

  std::vector<uint8_t> payload(
    (std::istreambuf_iterator<char>(file)),
    std::istreambuf_iterator<char>()
  );

  sendBinaryResponse(payload);
  return true;
}

bool TCPServer::ClientSession::getMarkerFile(const std::vector<std::string>& params) {
  if (params.size() != 1) return false;
  MarkerFileInfo chosen;
  if (!server_.findMarkerFileById(params[0], chosen)) {
    if (server_.logger_) {
      server_.logger_->warning(clientLogMessage("GETMARKER received an invalid marker file id."));
    }
    return false;
  }
  std::ifstream file(chosen.filename, std::ios::binary);
  if (!file) {
    if (server_.logger_) {
      server_.logger_->error(clientLogMessage("Failed to open marker file: " + chosen.filename));
    }
    return false;
  }
  std::vector<uint8_t> payload((std::istreambuf_iterator<char>(file)),
                               std::istreambuf_iterator<char>());
  if (payload.size() != chosen.byteCount) {
    if (server_.logger_) {
      server_.logger_->error(clientLogMessage("Marker file size changed while reading: " + chosen.filename));
    }
    return false;
  }
  sendBinaryResponse(payload);
  return true;
}

bool TCPServer::ClientSession::getMeshFile(const std::vector<std::string>& params) {
  if (params.size() != 1) return false;
  MeshFileInfo chosen;
  if (!server_.findMeshFileById(params[0], chosen)) {
    if (server_.logger_) {
      server_.logger_->warning(clientLogMessage("GETMESH received an invalid mesh id."));
    }
    return false;
  }
  std::ifstream file(chosen.filename, std::ios::binary);
  if (!file) {
    if (server_.logger_) {
      server_.logger_->error(clientLogMessage("Failed to open mesh file: " + chosen.filename));
    }
    return false;
  }
  std::vector<uint8_t> payload((std::istreambuf_iterator<char>(file)),
                               std::istreambuf_iterator<char>());
  if (payload.size() != chosen.byteCount) {
    if (server_.logger_) {
      server_.logger_->error(clientLogMessage("Mesh file size changed while reading: " + chosen.filename));
    }
    return false;
  }
  sendBinaryResponse(payload);
  return true;
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
        server_.logger_->warning(clientLogMessage(
          "GETBRICKS index out of range: " + std::to_string(idx) +
          " (valid 0.." + std::to_string(brickCount - 1) + ")"
        ));
      }
      return false;
    }
  }

  size_t totalSize = 0;
  for (int idx : indices) {
    const auto& bm = md.getBrickMetadata(idx);
    if (bm.size < 0) return false;
    const size_t brickSize = static_cast<size_t>(bm.size);
    if (brickSize > static_cast<size_t>(INT32_MAX) - totalSize) {
      if (server_.logger_) {
        server_.logger_->warning(clientLogMessage(
          "GETBRICKS response exceeds the protocol size limit."
        ));
      }
      return false;
    }
    totalSize += brickSize;
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
    if (server_.logger_) {
      server_.logger_->error(clientLogMessage(std::string("GETBRICKS failed: ") + e.what()));
    }
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
    if (server_.logger_) {
      server_.logger_->warning(clientLogMessage("Rejecting unauthenticated command."));
    }
    return false;
  }

  if (cmd == "LIST") return sendList(params);
  if (cmd == "LISTTF") return sendTransferFunctionList(params);
  if (cmd == "LISTMARKERS") return sendMarkerFileList(params);
  if (cmd == "LISTMESHES") return sendMeshFileList(params);
  if (cmd == "INFO") return sendInfo(params);
  if (cmd == "OPEN") return openDataset(params);
  if (cmd == "GETTF") return getTransferFunction(params);
  if (cmd == "GETMARKER") return getMarkerFile(params);
  if (cmd == "GETMESH") return getMeshFile(params);
  if (cmd == "GETBRICKS") return getBricks(params);

  return false;
}

void TCPServer::ClientSession::run() {
  try {
    if (server_.logger_) server_.logger_->info(clientLogMessage("Client connected."));

    std::string buffer;
    buffer.reserve(4096);
    constexpr size_t kMaxLineBytes = 8 * 1024;
    const auto sessionStartedAt = std::chrono::steady_clock::now();
    auto partialCommandStartedAt = sessionStartedAt;
    bool hasPartialCommand = false;

    uint8_t temp[1024];

    while (running_.load() && server_.running_.load() && socket_.valid()) {
      const int rc = socket_.recvSome(temp, sizeof(temp));
      if (rc < 0) {
        const bool expectedDisconnect = socket_.lastReceiveTimedOut() ||
                                        socket_.lastReceiveWasPeerDisconnect();
        if (server_.logger_ && !expectedDisconnect) {
          server_.logger_->warning(clientLogMessage("Receive error; disconnecting."));
        }
        break;
      }
      if (rc == 0) {
        // orderly shutdown
        break;
      }

      const bool bufferWasEmpty = buffer.empty();
      buffer.append(reinterpret_cast<const char*>(temp), static_cast<size_t>(rc));
      const auto now = std::chrono::steady_clock::now();
      if (bufferWasEmpty && !buffer.empty()) {
        partialCommandStartedAt = now;
        hasPartialCommand = true;
      }
      if (!server_.authSecret_.empty() && !authenticated_ &&
          now - sessionStartedAt > std::chrono::milliseconds(BORGVR_AUTHENTICATION_TIMEOUT_MS)) {
        if (server_.logger_) {
          server_.logger_->warning(clientLogMessage("Authentication deadline exceeded; disconnecting."));
        }
        break;
      }
      if (hasPartialCommand &&
          now - partialCommandStartedAt > std::chrono::milliseconds(BORGVR_PARTIAL_INPUT_TIMEOUT_MS)) {
        if (server_.logger_) {
          server_.logger_->warning(clientLogMessage("Command receive deadline exceeded; disconnecting."));
        }
        break;
      }
      if (buffer.size() > kMaxLineBytes * 4) {
        if (server_.logger_) {
          server_.logger_->warning(clientLogMessage("Input buffer too large; disconnecting."));
        }
        break;
      }

      for (;;) {
        const auto pos = buffer.find('\n');
        if (pos == std::string::npos) break;

        std::string line = buffer.substr(0, pos);
        buffer.erase(0, pos + 1);
        if (buffer.empty()) {
          hasPartialCommand = false;
        } else {
          partialCommandStartedAt = now;
          hasPartialCommand = true;
        }

        line = trim(line);
        if (line.empty()) {
          running_.store(false);
          break;
        }
        if (line.size() > kMaxLineBytes) {
          if (server_.logger_) {
            server_.logger_->warning(clientLogMessage("Command line too long; disconnecting."));
          }
          running_.store(false);
          break;
        }

        if (!processCommand(line)) {
          if (server_.logger_) {
            server_.logger_->warning(clientLogMessage(
              "Rejected malformed or unsupported protocol command."
            ));
          }
          running_.store(false);
          break;
        }
        if (!running_.load()) {
          break;
        }
      }
    }
  } catch (const std::exception& e) {
    if (server_.logger_) {
      server_.logger_->warning(clientLogMessage(std::string("Client session aborted: ") + e.what()));
    }
  } catch (...) {
    if (server_.logger_) {
      server_.logger_->warning(clientLogMessage("Client session aborted with an unknown exception."));
    }
  }

  stop();
  if (server_.logger_) server_.logger_->info(clientLogMessage("Client disconnected."));
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
