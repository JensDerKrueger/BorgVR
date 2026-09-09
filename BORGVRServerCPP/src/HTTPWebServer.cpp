#include "HTTPWebServer.h"

#include "BORGVRFileData.h"
#include "GeneratedWebAssets.h"
#include "LZ4.h"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstring>
#include <iomanip>
#include <limits>
#include <sstream>

namespace {

constexpr size_t kChunkedResponseThreshold = 1024 * 1024;
constexpr size_t kHTTPChunkBytes = 16 * 1024;
constexpr size_t kAppleLZ4BlockBytes = 64 * 1024;

class HandlerCounter {
public:
  explicit HandlerCounter(std::atomic<int>& counter) : counter_(counter) {
    counter_.fetch_add(1);
  }

  ~HandlerCounter() {
    counter_.fetch_sub(1);
  }

  HandlerCounter(const HandlerCounter&) = delete;
  HandlerCounter& operator=(const HandlerCounter&) = delete;

private:
  std::atomic<int>& counter_;
};

std::string trimCopy(const std::string& s) {
  size_t start = 0;
  while (start < s.size() && std::isspace(static_cast<unsigned char>(s[start]))) ++start;
  size_t end = s.size();
  while (end > start && std::isspace(static_cast<unsigned char>(s[end - 1]))) --end;
  return s.substr(start, end - start);
}

std::string lowerCopy(std::string s) {
  std::transform(s.begin(), s.end(), s.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return s;
}

bool constantTimeEquals(const std::string& a, const std::string& b) {
  size_t diff = a.size() ^ b.size();
  const size_t count = std::min(a.size(), b.size());
  for (size_t i = 0; i < count; ++i) {
    diff |= static_cast<unsigned char>(a[i]) ^ static_cast<unsigned char>(b[i]);
  }
  return diff == 0;
}

int base64Value(char c) {
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a' + 26;
  if (c >= '0' && c <= '9') return c - '0' + 52;
  if (c == '+') return 62;
  if (c == '/') return 63;
  if (c == '=') return -2;
  return -1;
}

bool base64Decode(const std::string& text, std::string& out) {
  out.clear();
  if (text.empty() || text.size() % 4 != 0) return false;

  std::vector<uint8_t> bytes;
  bytes.reserve((text.size() / 4) * 3);
  for (size_t i = 0; i < text.size(); i += 4) {
    const int v0 = base64Value(text[i]);
    const int v1 = base64Value(text[i + 1]);
    const int v2 = base64Value(text[i + 2]);
    const int v3 = base64Value(text[i + 3]);
    if (v0 < 0 || v1 < 0 || v2 == -1 || v3 == -1) return false;

    const uint32_t triple =
      (static_cast<uint32_t>(v0) << 18) |
      (static_cast<uint32_t>(v1) << 12) |
      (static_cast<uint32_t>(v2 < 0 ? 0 : v2) << 6) |
      static_cast<uint32_t>(v3 < 0 ? 0 : v3);
    bytes.push_back(static_cast<uint8_t>((triple >> 16) & 0xff));
    if (v2 != -2) bytes.push_back(static_cast<uint8_t>((triple >> 8) & 0xff));
    if (v3 != -2) bytes.push_back(static_cast<uint8_t>(triple & 0xff));
  }

  out.assign(reinterpret_cast<const char*>(bytes.data()), bytes.size());
  return true;
}

std::string headerValue(const HTTPWebServer::Request& request, const std::string& name) {
  const std::string lowerName = lowerCopy(name);
  for (const auto& header : request.headers) {
    if (lowerCopy(header.first) == lowerName) {
      return header.second;
    }
  }
  return "";
}

std::string jsonEscape(const std::string& text) {
  std::ostringstream oss;
  for (unsigned char c : text) {
    switch (c) {
      case '\\': oss << "\\\\"; break;
      case '"': oss << "\\\""; break;
      case '\b': oss << "\\b"; break;
      case '\f': oss << "\\f"; break;
      case '\n': oss << "\\n"; break;
      case '\r': oss << "\\r"; break;
      case '\t': oss << "\\t"; break;
      default:
        if (c < 0x20) {
          oss << "\\u" << std::hex << std::setw(4) << std::setfill('0') << static_cast<int>(c)
              << std::dec << std::setfill(' ');
        } else {
          oss << static_cast<char>(c);
        }
        break;
    }
  }
  return oss.str();
}

bool parseUnsigned(const std::string& text, size_t& out) {
  if (text.empty()) return false;
  size_t value = 0;
  for (char c : text) {
    if (!std::isdigit(static_cast<unsigned char>(c))) return false;
    const size_t digit = static_cast<size_t>(c - '0');
    if (value > (std::numeric_limits<size_t>::max() - digit) / 10) return false;
    value = value * 10 + digit;
  }
  out = value;
  return true;
}

std::string urlDecode(const std::string& text) {
  std::string out;
  out.reserve(text.size());
  for (size_t i = 0; i < text.size(); ++i) {
    if (text[i] == '%' && i + 2 < text.size()) {
      const auto hex = text.substr(i + 1, 2);
      char* end = nullptr;
      const long value = std::strtol(hex.c_str(), &end, 16);
      if (end && *end == '\0') {
        out.push_back(static_cast<char>(value));
        i += 2;
        continue;
      }
    }
    out.push_back(text[i] == '+' ? ' ' : text[i]);
  }
  return out;
}

std::string stripQueryAndFragment(const std::string& target) {
  const auto pos = target.find_first_of("?#");
  return pos == std::string::npos ? target : target.substr(0, pos);
}

std::string displayNameFor(const DatasetInfo& dataset) {
  if (!dataset.datasetDescription.empty()) {
    return dataset.datasetDescription;
  }
  const auto slash = dataset.filename.find_last_of("/\\");
  const std::string basename = slash == std::string::npos ? dataset.filename : dataset.filename.substr(slash + 1);
  const auto dot = basename.find_last_of('.');
  return dot == std::string::npos ? basename : basename.substr(0, dot);
}

std::string variantName(const BORGVRMetaData& md) {
  return md.compression() ? "compressed" : "raw";
}

std::string datasetCompressionName(const BORGVRMetaData& md) {
  return md.compression() ? "lz4" : "none";
}

uint64_t dataTypeMaxValue(const BORGVRMetaData& md) {
  const int bits = md.bytesPerComponent() * 8;
  if (bits <= 0) {
    return 1;
  }
  if (bits >= 63) {
    return std::numeric_limits<uint64_t>::max();
  }
  return (uint64_t{1} << bits) - 1;
}

void appendLE32(std::vector<uint8_t>& out, uint32_t value) {
  out.push_back(static_cast<uint8_t>(value & 0xff));
  out.push_back(static_cast<uint8_t>((value >> 8) & 0xff));
  out.push_back(static_cast<uint8_t>((value >> 16) & 0xff));
  out.push_back(static_cast<uint8_t>((value >> 24) & 0xff));
}

std::vector<uint8_t> encodeAppleLZ4Stream(const std::string& text) {
  const auto* input = reinterpret_cast<const uint8_t*>(text.data());
  size_t offset = 0;
  std::vector<uint8_t> out;
  out.reserve(text.size() / 2);

  while (offset < text.size()) {
    const size_t blockLength = std::min(kAppleLZ4BlockBytes, text.size() - offset);
    std::vector<uint8_t> compressed(lz4::compressBlockBound(blockLength));
    const size_t compressedLength = lz4::compressBlock(input + offset,
                                                       blockLength,
                                                       compressed.data(),
                                                       compressed.size());
    if (compressedLength == 0) {
      return {};
    }

    out.insert(out.end(), {'b', 'v', '4', '1'});
    appendLE32(out, static_cast<uint32_t>(blockLength));
    appendLE32(out, static_cast<uint32_t>(compressedLength));
    out.insert(out.end(), compressed.begin(), compressed.begin() + static_cast<ptrdiff_t>(compressedLength));
    offset += blockLength;
  }

  out.insert(out.end(), {'b', 'v', '4', '$'});
  return out;
}

} // namespace

HTTPWebServer::HTTPWebServer(uint16_t port,
                             TCPServer& datasetServer,
                             std::shared_ptr<Logger> logger,
                             std::string authSecret)
  : port_(port),
    datasetServer_(datasetServer),
    logger_(std::move(logger)),
    authSecret_(trimCopy(authSecret)) {}

HTTPWebServer::~HTTPWebServer() {
  stop();
}

bool HTTPWebServer::start() {
  if (running_.load()) return true;

  if (!listener_.listenLocalhost(port_)) {
    if (logger_) logger_->error("Failed to listen for HTTP/WebGPU on localhost port " + std::to_string(port_));
    return false;
  }

  running_.store(true);
  acceptThread_ = std::thread([this]() { acceptLoop(); });
  if (logger_) {
    logger_->info("HTTP/WebGPU server started on http://localhost:" + std::to_string(port_));
  }
  return true;
}

void HTTPWebServer::stop() {
  if (!running_.exchange(false)) {
    return;
  }

  listener_.close();
  if (acceptThread_.joinable()) {
    acceptThread_.join();
  }
  while (activeHandlers_.load() > 0) {
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  if (logger_) logger_->info("HTTP/WebGPU server stopped");
}

void HTTPWebServer::acceptLoop() {
  while (running_.load()) {
    TcpSocket client = listener_.accept();
    if (!client.valid()) {
      if (!running_.load()) break;
      std::this_thread::sleep_for(std::chrono::milliseconds(20));
      continue;
    }

    try {
      std::thread([this](TcpSocket socket) {
        HandlerCounter counter(activeHandlers_);
        try {
          handleClient(std::move(socket));
        } catch (const std::exception& e) {
          if (logger_) logger_->warning(std::string("HTTP client handler aborted: ") + e.what());
        } catch (...) {
          if (logger_) logger_->warning("HTTP client handler aborted with an unknown exception.");
        }
      }, std::move(client)).detach();
    } catch (const std::exception& e) {
      if (logger_) logger_->error(std::string("Failed to start HTTP client thread: ") + e.what());
    }
  }
}

void HTTPWebServer::handleClient(TcpSocket socket) {
  Request request;
  if (!parseRequest(socket, request)) {
    return;
  }

  if (request.method == "OPTIONS") {
    sendTextResponse(socket, 204, "No Content", "text/plain; charset=utf-8", "",
                     {{"Access-Control-Allow-Methods", "GET, OPTIONS"},
                      {"Access-Control-Allow-Headers", "Authorization, Content-Type"}});
    return;
  }

  if (request.method != "GET") {
    sendError(socket, 405, "Method Not Allowed", "Only GET is supported.");
    return;
  }

  if (!isAuthorized(request)) {
    sendUnauthorized(socket);
    return;
  }

  if (!routeRequest(socket, request)) {
    sendError(socket, 404, "Not Found", "No resource exists at this path.");
  }
}

bool HTTPWebServer::parseRequest(TcpSocket& socket, Request& request) const {
  std::string buffer;
  buffer.reserve(4096);
  uint8_t temp[1024];

  constexpr size_t kMaxHeaderBytes = 32 * 1024;
  while (buffer.find("\r\n\r\n") == std::string::npos &&
         buffer.find("\n\n") == std::string::npos &&
         buffer.size() < kMaxHeaderBytes) {
    const int rc = socket.recvSome(temp, sizeof(temp));
    if (rc <= 0) return false;
    buffer.append(reinterpret_cast<const char*>(temp), static_cast<size_t>(rc));
  }

  const auto headerEndCRLF = buffer.find("\r\n\r\n");
  const auto headerEndLF = buffer.find("\n\n");
  size_t headerEnd = std::string::npos;
  if (headerEndCRLF != std::string::npos) {
    headerEnd = headerEndCRLF;
  } else if (headerEndLF != std::string::npos) {
    headerEnd = headerEndLF;
  }
  if (headerEnd == std::string::npos) {
    return false;
  }

  std::string headerText = buffer.substr(0, headerEnd);
  std::replace(headerText.begin(), headerText.end(), '\r', '\n');

  std::istringstream lines(headerText);
  std::string line;
  if (!std::getline(lines, line)) return false;

  {
    std::istringstream firstLine(trimCopy(line));
    std::string version;
    firstLine >> request.method >> request.target >> version;
    if (request.method.empty() || request.target.empty()) return false;
  }

  request.path = urlDecode(stripQueryAndFragment(request.target));
  if (request.path.empty() || request.path[0] != '/') {
    request.path = "/" + request.path;
  }

  while (std::getline(lines, line)) {
    line = trimCopy(line);
    if (line.empty()) continue;
    const auto colon = line.find(':');
    if (colon == std::string::npos) continue;
    request.headers.emplace_back(trimCopy(line.substr(0, colon)), trimCopy(line.substr(colon + 1)));
  }

  return true;
}

bool HTTPWebServer::isAuthorized(const Request& request) const {
  if (authSecret_.empty()) {
    return true;
  }

  const std::string authorization = headerValue(request, "Authorization");
  constexpr const char* prefix = "Basic ";
  if (authorization.size() <= 6 || authorization.compare(0, 6, prefix) != 0) {
    return false;
  }

  std::string credentials;
  if (!base64Decode(authorization.substr(6), credentials)) {
    return false;
  }

  const auto colon = credentials.find(':');
  const std::string password = colon == std::string::npos ? credentials : credentials.substr(colon + 1);
  return constantTimeEquals(password, authSecret_);
}

bool HTTPWebServer::routeRequest(TcpSocket& socket, const Request& request) {
  if (request.path == "/web-data/datasets.json") {
    return sendCatalog(socket);
  }

  constexpr const char* datasetPrefix = "/web-data/datasets/";
  const std::string prefix(datasetPrefix);
  if (request.path.compare(0, prefix.size(), prefix) == 0) {
    const std::string rest = request.path.substr(prefix.size());
    const auto slash = rest.find('/');
    if (slash == std::string::npos) {
      return false;
    }

    const std::string datasetID = rest.substr(0, slash);
    const std::string tail = rest.substr(slash + 1);
    if (tail == "dataset.json.lz4") {
      return sendDatasetManifest(socket, datasetID);
    }

    constexpr const char* bricksPrefix = "bricks/";
    const std::string bricks(bricksPrefix);
    if (tail.compare(0, bricks.size(), bricks) == 0) {
      return sendBrick(socket, datasetID, tail.substr(bricks.size()));
    }
  }

  return sendStaticFile(socket, request.path);
}

bool HTTPWebServer::sendCatalog(TcpSocket& socket) {
  const auto datasets = datasetServer_.datasetsSnapshot();

  std::ostringstream oss;
  oss << "{\n"
      << "  \"format\": \"borgvr-web-catalog\",\n"
      << "  \"version\": 1,\n"
      << "  \"generatedAt\": \"dynamic\",\n"
      << "  \"datasets\": [\n";

  for (size_t i = 0; i < datasets.size(); ++i) {
    const auto& dataset = datasets[i];
    const std::string name = displayNameFor(dataset);
    oss << "    {\n"
        << "      \"catalogID\": \"" << jsonEscape(dataset.id + "#server") << "\",\n"
        << "      \"id\": \"" << jsonEscape(dataset.id) << "\",\n"
        << "      \"name\": \"" << jsonEscape(name) << "\",\n"
        << "      \"description\": \"" << jsonEscape(dataset.datasetDescription.empty() ? name : dataset.datasetDescription) << "\",\n"
        << "      \"metadata\": \"datasets/" << jsonEscape(dataset.id) << "/dataset.json.lz4\",\n"
        << "      \"variant\": \"server\"\n"
        << "    }" << (i + 1 < datasets.size() ? "," : "") << "\n";
  }

  oss << "  ]\n"
      << "}\n";
  return sendTextResponse(socket, 200, "OK", "application/json; charset=utf-8", oss.str());
}

bool HTTPWebServer::sendDatasetManifest(TcpSocket& socket, const std::string& datasetID) {
  DatasetInfo info;
  if (!datasetServer_.findDatasetById(datasetID, info)) {
    return false;
  }

  try {
    BORGVRFileData dataset(info.filename);
    const BORGVRMetaData& md = dataset.metadata();
    const uint64_t dataRangeMax = dataTypeMaxValue(md);

    std::ostringstream oss;
    oss << "{\n"
        << "  \"format\": \"borgvr-web-dataset\",\n"
        << "  \"version\": 1,\n"
        << "  \"id\": \"" << jsonEscape(md.uniqueID()) << "\",\n"
        << "  \"name\": \"" << jsonEscape(displayNameFor(info)) << "\",\n"
        << "  \"description\": \"" << jsonEscape(info.datasetDescription) << "\",\n"
        << "  \"metaDescription\": \"" << jsonEscape(md.metaDescription()) << "\",\n"
        << "  \"variant\": \"" << variantName(md) << "\",\n"
        << "  \"volume\": {\n"
        << "    \"size\": [" << md.width() << ", " << md.height() << ", " << md.depth() << "],\n"
        << "    \"aspect\": [" << md.aspectX() << ", " << md.aspectY() << ", " << md.aspectZ() << "],\n"
        << "    \"componentCount\": " << md.componentCount() << ",\n"
        << "    \"bytesPerComponent\": " << md.bytesPerComponent() << ",\n"
        << "    \"valueType\": \"uint\",\n"
        << "    \"endianness\": \"little\",\n"
        << "    \"valueRange\": [" << md.minValue() << ", " << md.maxValue() << "],\n"
        << "    \"dataRange\": [0, " << dataRangeMax << "]\n"
        << "  },\n"
        << "  \"bricking\": {\n"
        << "    \"brickSize\": " << md.brickSize() << ",\n"
        << "    \"overlap\": " << md.overlap() << ",\n"
        << "    \"indexing\": \"borgvr-linear\",\n"
        << "    \"brickOrder\": \"x-fastest-y-z\",\n"
        << "    \"compression\": \"" << datasetCompressionName(md) << "\",\n"
        << "    \"supportedCompressions\": [\"none\", \"lz4\"]\n"
        << "  },\n"
        << "  \"levels\": [\n";

    const auto& levels = md.levelMetadata();
    for (size_t i = 0; i < levels.size(); ++i) {
      const auto& level = levels[i];
      const int total = level.totalBricks.x * level.totalBricks.y * level.totalBricks.z;
      oss << "    {\n"
          << "      \"level\": " << i << ",\n"
          << "      \"size\": [" << level.size.x << ", " << level.size.y << ", " << level.size.z << "],\n"
          << "      \"brickCount\": [" << level.totalBricks.x << ", " << level.totalBricks.y << ", " << level.totalBricks.z << "],\n"
          << "      \"brickTotal\": " << total << ",\n"
          << "      \"firstBrick\": " << level.prevBricks << "\n"
          << "    }" << (i + 1 < levels.size() ? "," : "") << "\n";
    }

    oss << "  ],\n"
        << "  \"brickMetadata\": {\n"
        << "    \"format\": \"min-max-byteLength-v1\",\n"
        << "    \"fields\": [\"min\", \"max\", \"byteLength\"],\n"
        << "    \"values\": [\n";

    const auto& bricks = md.brickMetadata();
    for (size_t i = 0; i < bricks.size(); ++i) {
      const auto& bm = bricks[i];
      oss << "      " << bm.minValue << ", " << bm.maxValue << ", " << bm.size
          << (i + 1 < bricks.size() ? "," : "") << "\n";
    }

    oss << "    ]\n"
        << "  }\n"
        << "}\n";

    const std::string json = oss.str();
    auto body = encodeAppleLZ4Stream(json);
    if (body.empty() && !json.empty()) {
      return sendError(socket, 500, "Internal Server Error", "Unable to compress dataset metadata.");
    }
    return sendResponse(socket,
                        200,
                        "OK",
                        "application/octet-stream",
                        body,
                        {{"X-BorgVR-Uncompressed-Length", std::to_string(json.size())},
                         {"X-BorgVR-Content", "dataset-manifest-lz4"}});
  } catch (const std::exception& e) {
    if (logger_) logger_->error(std::string("HTTP manifest failed: ") + e.what());
    return sendError(socket, 500, "Internal Server Error", "Unable to open dataset metadata.");
  }
}

bool HTTPWebServer::sendBrick(TcpSocket& socket, const std::string& datasetID, const std::string& filename) {
  DatasetInfo info;
  if (!datasetServer_.findDatasetById(datasetID, info)) {
    return false;
  }

  size_t brickIndex = 0;
  if (!parseUnsigned(filename, brickIndex)) {
    return false;
  }

  try {
    BORGVRFileData dataset(info.filename);
    const BORGVRMetaData& md = dataset.metadata();
    if (brickIndex >= md.brickMetadata().size()) {
      return false;
    }

    const auto& bm = md.getBrickMetadata(static_cast<int>(brickIndex));
    const size_t byteCount = static_cast<size_t>(bm.size);
    std::vector<uint8_t> body(byteCount);
    dataset.getRawBrick(bm, body.data(), body.size());
    return sendResponse(socket, 200, "OK", "application/octet-stream", body);
  } catch (const std::exception& e) {
    if (logger_) logger_->error(std::string("HTTP brick failed: ") + e.what());
    return sendError(socket, 500, "Internal Server Error", "Unable to read brick.");
  }
}

bool HTTPWebServer::sendStaticFile(TcpSocket& socket, const std::string& requestPath) {
  const EmbeddedWebAsset* asset = findEmbeddedWebAsset(requestPath.c_str());
  if (!asset) {
    return false;
  }

  std::vector<uint8_t> body(asset->data, asset->data + asset->size);
  return sendResponse(socket, 200, "OK", asset->contentType, body);
}

bool HTTPWebServer::sendResponse(TcpSocket& socket,
                                 int status,
                                 const std::string& reason,
                                 const std::string& contentType,
                                 const std::vector<uint8_t>& body,
                                 const std::vector<std::pair<std::string, std::string>>& extraHeaders) const {
  if (body.size() >= kChunkedResponseThreshold) {
    return sendChunkedResponse(socket, status, reason, contentType, body, extraHeaders);
  }

  std::ostringstream header;
  header << "HTTP/1.1 " << status << " " << reason << "\r\n"
         << "Content-Length: " << body.size() << "\r\n"
         << "Content-Type: " << contentType << "\r\n"
         << "Connection: close\r\n"
         << "Access-Control-Allow-Origin: *\r\n"
         << "Access-Control-Expose-Headers: X-BorgVR-Uncompressed-Length\r\n"
         << "Cache-Control: no-store\r\n";
  for (const auto& item : extraHeaders) {
    header << item.first << ": " << item.second << "\r\n";
  }
  header << "\r\n";

  if (!socket.sendAll(header.str())) {
    if (logger_) logger_->warning("HTTP response header send failed for status " + std::to_string(status));
    return false;
  }
  if (!body.empty() && !socket.sendAll(body)) {
    if (logger_) {
      logger_->warning("HTTP response body send failed for status " + std::to_string(status) +
                       " with " + std::to_string(body.size()) + " bytes");
    }
    return false;
  }
  return true;
}

bool HTTPWebServer::sendChunkedResponse(TcpSocket& socket,
                                        int status,
                                        const std::string& reason,
                                        const std::string& contentType,
                                        const std::vector<uint8_t>& body,
                                        const std::vector<std::pair<std::string, std::string>>& extraHeaders) const {
  std::ostringstream header;
  header << "HTTP/1.1 " << status << " " << reason << "\r\n"
         << "Transfer-Encoding: chunked\r\n"
         << "Content-Type: " << contentType << "\r\n"
         << "Connection: close\r\n"
         << "Access-Control-Allow-Origin: *\r\n"
         << "Access-Control-Expose-Headers: X-BorgVR-Uncompressed-Length\r\n"
         << "Cache-Control: no-store\r\n";
  for (const auto& item : extraHeaders) {
    header << item.first << ": " << item.second << "\r\n";
  }
  header << "\r\n";

  if (!socket.sendAll(header.str())) {
    if (logger_) logger_->warning("HTTP chunked response header send failed for status " + std::to_string(status));
    return false;
  }

  size_t offset = 0;
  while (offset < body.size()) {
    const size_t chunkSize = std::min(kHTTPChunkBytes, body.size() - offset);

    std::ostringstream chunkHeader;
    chunkHeader << std::hex << chunkSize << "\r\n";
    if (!socket.sendAll(chunkHeader.str()) ||
        !socket.sendAll(body.data() + offset, chunkSize) ||
        !socket.sendAll("\r\n")) {
      if (logger_) {
        logger_->warning("HTTP chunked response body send failed for status " + std::to_string(status) +
                         " at offset " + std::to_string(offset) +
                         " of " + std::to_string(body.size()) + " bytes");
      }
      return false;
    }

    offset += chunkSize;
  }

  if (!socket.sendAll("0\r\n\r\n")) {
    if (logger_) logger_->warning("HTTP chunked response terminator send failed for status " + std::to_string(status));
    return false;
  }

  return true;
}

bool HTTPWebServer::sendTextResponse(TcpSocket& socket,
                                     int status,
                                     const std::string& reason,
                                     const std::string& contentType,
                                     const std::string& body,
                                     const std::vector<std::pair<std::string, std::string>>& extraHeaders) const {
  return sendResponse(socket,
                      status,
                      reason,
                      contentType,
                      std::vector<uint8_t>(body.begin(), body.end()),
                      extraHeaders);
}

bool HTTPWebServer::sendError(TcpSocket& socket, int status, const std::string& reason, const std::string& message) const {
  std::ostringstream body;
  body << "{\n"
       << "  \"error\": \"" << jsonEscape(reason) << "\",\n"
       << "  \"message\": \"" << jsonEscape(message) << "\"\n"
       << "}\n";
  return sendTextResponse(socket, status, reason, "application/json; charset=utf-8", body.str());
}

bool HTTPWebServer::sendUnauthorized(TcpSocket& socket) const {
  return sendTextResponse(socket,
                          401,
                          "Unauthorized",
                          "application/json; charset=utf-8",
                          "{\n  \"error\": \"Unauthorized\",\n  \"message\": \"A BorgVR server password is required.\"\n}\n",
                          {{"WWW-Authenticate", "Basic realm=\"BorgVR Dataset Server\""}});
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
