#include "HTTPWebServer.h"
#include "TCPServer.h"
#include "BORGVRMetaData.h"
#include "BorgVRFormatConstants.h"
#include "Logger.h"
#include "ServerSync.h"
#include "Socket.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cctype>
#include <cstdint>
#include <cstdlib>
#include <exception>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <sstream>
#include <thread>
#include <unordered_set>
#include <vector>

#ifndef BORGVR_BUILD_TIMESTAMP
#define BORGVR_BUILD_TIMESTAMP "unknown"
#endif

#ifndef BORGVR_SERVER_VERSION
#define BORGVR_SERVER_VERSION "2.7"
#endif

struct ServerConfiguration {
  std::string datasetDirectory;
  uint16_t port = 12345;
  int maxBricksPerGetRequest = 64;
  std::string password;
  int scanIntervalSeconds = 10;
  uint16_t webPort = 0;
  std::string logFile;
  std::vector<ServerSyncEndpoint> syncServers;
};

static std::string basenameOf(const std::string& path) {
  const auto slash = path.find_last_of("/\\");
  if (slash == std::string::npos) return path;
  return path.substr(slash + 1);
}

static bool parseUint16(const std::string& s, uint16_t& out) {
  try {
    size_t idx = 0;
    int v = std::stoi(s, &idx, 10);
    if (idx != s.size()) return false;
    if (v <= 0 || v > 65535) return false;
    out = static_cast<uint16_t>(v);
    return true;
  } catch (...) {
    return false;
  }
}

static bool parseInt(const std::string& s, int& out) {
  try {
    size_t idx = 0;
    int v = std::stoi(s, &idx, 10);
    if (idx != s.size()) return false;
    out = v;
    return true;
  } catch (...) {
    return false;
  }
}

static std::string defaultDatasetDirectory() {
#if defined(_WIN32)
  const char* home = std::getenv("USERPROFILE");
#else
  const char* home = std::getenv("HOME");
#endif
  return home && *home ? std::string(home) : std::filesystem::current_path().string();
}

static void printUsage(const char* filename) {
  const std::string executable = basenameOf(filename);
  std::cout
    << "Usage:\n"
    << "  " << executable << " [options]\n\n"
    << "Options:\n"
    << "  --directory, -d <path>          Directory containing .data, .tf1d, .marker, and .mesh files.\n"
    << "                                  Defaults to the home directory.\n"
    << "  --port, -p <port>               Native dataset-server port. Defaults to 12345.\n"
    << "  --max-bricks, -m <count>        Maximum bricks per GETBRICKS request. Defaults to 64.\n"
    << "  --password <secret>             Optional password for native and WebGPU clients.\n"
    << "  --scan-interval <seconds>       Refresh the file catalog periodically.\n"
    << "                                  Defaults to 10; use 0 to disable rescanning.\n"
    << "  --web-port <port>               Enable the WebGPU HTTP server on this port.\n"
    << "  --log-file <path>               Also append log messages to this file.\n"
    << "  --sync-server <host> <port> <interval> [password]\n"
    << "                                  Synchronize server content at intervals of at least\n"
    << "                                  10 seconds. Repeat for fallback sources.\n"
    << "  --version, -v                   Show the version.\n"
    << "  --help, -h                      Show this help.\n\n"
    << "Examples:\n"
    << "  " << executable << " --directory /data/BorgVR --port 12345\n"
    << "  " << executable << " -d /data/BorgVR -p 12345 -m 64 --web-port 8080 --log-file server.log\n"
    << "  " << executable << " -d /data/BorgVR --sync-server 192.168.1.10 12345 300 secret\n";
}

static void printStartupBanner(const ServerConfiguration& configuration) {
  constexpr const char* cyan = "\033[36m";
  constexpr const char* reset = "\033[0m";
  std::cout
    << cyan << "\n"
    << "  ____                   __     ______\n"
    << " | __ )  ___  _ __ __ _ \\ \\   / /  _ \\\n"
    << " |  _ \\ / _ \\| '__/ _` | \\ \\ / /| |_) |\n"
    << " | |_) | (_) | | | (_| |  \\ V / |  _ <\n"
    << " |____/ \\___/|_|  \\__, |   \\_/  |_| \\_\\\n"
    << "                  |___/\n"
    << reset << "\n"
    << " BorgVR Dataset Server\n"
    << " ------------------------------------------------------------\n"
    << " Version           : " << BORGVR_SERVER_VERSION << "\n"
    << " Build             : " << BORGVR_BUILD_TIMESTAMP << "\n"
    << " Dataset directory : " << configuration.datasetDirectory << "\n"
    << " Dataset port      : " << configuration.port << "\n"
    << " Max brick batch   : " << configuration.maxBricksPerGetRequest << "\n"
    << " Scan interval     : ";

  if (configuration.scanIntervalSeconds > 0) {
    std::cout << configuration.scanIntervalSeconds << " s\n";
  } else {
    std::cout << "disabled\n";
  }
  std::cout << " Password          : "
            << (configuration.password.empty() ? "disabled" : "enabled") << "\n";
  std::cout << " Log level         : info (l1)\n"
            << " Log file          : "
            << (configuration.logFile.empty() ? "disabled" : configuration.logFile) << "\n";

  if (configuration.webPort > 0) {
    std::cout << " WebGPU frontend   : http://localhost:" << configuration.webPort << "/\n";
  } else {
    std::cout << " WebGPU frontend   : disabled\n";
  }

  if (configuration.syncServers.empty()) {
    std::cout << " Sync servers      : disabled\n";
  } else {
    std::cout << " Sync servers      : " << configuration.syncServers.size() << "\n";
    for (const auto& endpoint : configuration.syncServers) {
      std::cout << "   - " << endpoint.address << ":" << endpoint.port
                << " every " << endpoint.intervalSeconds << " s"
                << (endpoint.password.empty() ? "" : " (password)") << "\n";
    }
  }

  std::cout
    << " ------------------------------------------------------------\n"
    << "\n"
    << std::flush;
}

static void logDatasetScanFailureOnce(const std::string& filename,
                                      const std::string& reason,
                                      std::shared_ptr<Logger> logger) {
  if (!logger) return;

  static std::mutex mutex;
  static std::unordered_set<std::string> reportedFiles;

  std::lock_guard<std::mutex> lock(mutex);
  if (reportedFiles.insert(filename).second) {
    logger->warning("Unable to load dataset file " + filename + ": " + reason);
  }
}

static uint32_t leftRotate(uint32_t value, uint32_t shift) {
  return (value << shift) | (value >> (32 - shift));
}

static std::string md5Hex(const uint8_t* input, size_t inputLength) {
  static constexpr uint32_t shifts[64] = {
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21
  };

  static constexpr uint32_t constants[64] = {
    0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
    0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
    0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
    0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
    0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
    0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
    0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
    0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
    0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
    0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
    0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
    0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
    0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
    0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
    0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
    0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391
  };

  std::vector<uint8_t> message(input, input + inputLength);
  const uint64_t bitLength = static_cast<uint64_t>(inputLength) * 8;
  message.push_back(0x80);
  while ((message.size() % 64) != 56) {
    message.push_back(0);
  }
  for (int i = 0; i < 8; ++i) {
    message.push_back(static_cast<uint8_t>((bitLength >> (8 * i)) & 0xff));
  }

  uint32_t a0 = 0x67452301;
  uint32_t b0 = 0xefcdab89;
  uint32_t c0 = 0x98badcfe;
  uint32_t d0 = 0x10325476;

  for (size_t offset = 0; offset < message.size(); offset += 64) {
    uint32_t words[16];
    for (int i = 0; i < 16; ++i) {
      const size_t j = offset + static_cast<size_t>(i) * 4;
      words[i] = static_cast<uint32_t>(message[j]) |
                 (static_cast<uint32_t>(message[j + 1]) << 8) |
                 (static_cast<uint32_t>(message[j + 2]) << 16) |
                 (static_cast<uint32_t>(message[j + 3]) << 24);
    }

    uint32_t a = a0;
    uint32_t b = b0;
    uint32_t c = c0;
    uint32_t d = d0;

    for (uint32_t i = 0; i < 64; ++i) {
      uint32_t f = 0;
      uint32_t g = 0;
      if (i < 16) {
        f = (b & c) | ((~b) & d);
        g = i;
      } else if (i < 32) {
        f = (d & b) | ((~d) & c);
        g = (5 * i + 1) % 16;
      } else if (i < 48) {
        f = b ^ c ^ d;
        g = (3 * i + 5) % 16;
      } else {
        f = c ^ (b | (~d));
        g = (7 * i) % 16;
      }

      const uint32_t temp = d;
      d = c;
      c = b;
      b = b + leftRotate(a + f + constants[i] + words[g], shifts[i]);
      a = temp;
    }

    a0 += a;
    b0 += b;
    c0 += c;
    d0 += d;
  }

  std::ostringstream oss;
  oss << std::hex << std::setfill('0');
  for (uint32_t value : {a0, b0, c0, d0}) {
    for (int i = 0; i < 4; ++i) {
      oss << std::setw(2) << static_cast<int>((value >> (8 * i)) & 0xff);
    }
  }
  return oss.str();
}

static bool readFileBytes(const std::string& filename, std::vector<uint8_t>& out) {
  std::ifstream file(filename, std::ios::binary);
  if (!file) return false;
  out.assign(std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>());
  return true;
}

static uint32_t readU32LE(const std::vector<uint8_t>& bytes, size_t offset) {
  return static_cast<uint32_t>(bytes[offset]) |
         (static_cast<uint32_t>(bytes[offset + 1]) << 8) |
         (static_cast<uint32_t>(bytes[offset + 2]) << 16) |
         (static_cast<uint32_t>(bytes[offset + 3]) << 24);
}

static std::string trimCopy(const std::string& text) {
  size_t start = 0;
  while (start < text.size() && std::isspace(static_cast<unsigned char>(text[start]))) {
    ++start;
  }
  size_t end = text.size();
  while (end > start && std::isspace(static_cast<unsigned char>(text[end - 1]))) {
    --end;
  }
  return text.substr(start, end - start);
}

static bool parseTransferFunctionFile(const std::string& filename,
                                      TransferFunctionInfo& out,
                                      std::string& reason) {
  std::vector<uint8_t> bytes;
  if (!readFileBytes(filename, bytes)) {
    reason = "unable to read file";
    return false;
  }
  if (bytes.size() > BorgVRFormat::kMaximumTransferFunctionFileBytes) {
    reason = "file exceeds supported size";
    return false;
  }
  if (bytes.size() < 4) {
    reason = "file too small";
    return false;
  }

  size_t cursor = 0;
  std::string description;
  uint32_t count = 0;
  const bool hasExtendedHeader =
    bytes.size() >= 4 &&
    std::equal(
      BorgVRFormat::kTransferFunctionMagic.begin(),
      BorgVRFormat::kTransferFunctionMagic.end(),
      bytes.begin()
    );

  if (hasExtendedHeader) {
    cursor = 4;
    if (bytes.size() < cursor + 12) {
      reason = "extended header too small";
      return false;
    }
    const uint32_t version = readU32LE(bytes, cursor);
    cursor += 4;
    if (version != BorgVRFormat::kTransferFunctionVersion) {
      reason = "unsupported transfer function version";
      return false;
    }
    const uint32_t descriptionByteCount = readU32LE(bytes, cursor);
    cursor += 4;
    count = readU32LE(bytes, cursor);
    cursor += 4;
    if (descriptionByteCount > BorgVRFormat::kMaximumTransferFunctionDescriptionBytes) {
      reason = "description exceeds supported size";
      return false;
    }
    if (descriptionByteCount > bytes.size() - cursor) {
      reason = "description exceeds file size";
      return false;
    }
    description.assign(reinterpret_cast<const char*>(bytes.data() + cursor), descriptionByteCount);
    cursor += descriptionByteCount;
  } else {
    count = readU32LE(bytes, cursor);
    cursor += 4;
  }

  if (static_cast<size_t>(count) > BorgVRFormat::kMaximumTransferFunctionEntryCount) {
    reason = "transfer function sample count is too large";
    return false;
  }
  const size_t rgbaByteCount = static_cast<size_t>(count) * 4;
  if (rgbaByteCount > bytes.size() - cursor) {
    reason = "RGBA payload exceeds file size";
    return false;
  }

  const auto basename = basenameOf(filename);
  const auto dot = basename.find_last_of('.');
  const std::string fallbackName = dot == std::string::npos ? basename : basename.substr(0, dot);

  out.id = md5Hex(bytes.data() + cursor, rgbaByteCount);
  out.filename = filename;
  const std::string trimmedDescription = trimCopy(description);
  out.transferFunctionDescription = trimmedDescription.empty() ? fallbackName : trimmedDescription;
  out.byteCount = bytes.size();
  return true;
}

static std::vector<DatasetInfo> scanDatasetDirectory(const std::string& directory,
                                                     std::shared_ptr<Logger> logger) {
  namespace fs = std::filesystem;

  std::vector<DatasetInfo> datasets;
  std::error_code ec;
  if (!fs::exists(directory, ec) || !fs::is_directory(directory, ec)) {
    if (logger) logger->error("Not a directory: " + directory);
    return datasets;
  }

  for (const auto& entry : fs::directory_iterator(directory, ec)) {
    if (ec) break;
    if (!entry.is_regular_file(ec)) continue;

    const auto path = entry.path();
    if (path.extension() != ".data") continue;

    const std::string filename = path.string();
    try {
      BORGVRMetaData md(filename);
      DatasetInfo info;
      info.id = md.uniqueID();
      info.filename = filename;
      info.datasetDescription = md.datasetDescription();
      info.width = md.width();
      info.height = md.height();
      info.depth = md.depth();
      info.voxelSpacingX = md.voxelSpacingX();
      info.voxelSpacingY = md.voxelSpacingY();
      info.voxelSpacingZ = md.voxelSpacingZ();
      datasets.push_back(std::move(info));
    } catch (const std::exception& e) {
      logDatasetScanFailureOnce(filename, e.what(), logger);
    } catch (...) {
      logDatasetScanFailureOnce(filename, "unknown error", logger);
    }
  }

  return datasets;
}

static std::vector<TransferFunctionInfo> scanTransferFunctionDirectory(const std::string& directory,
                                                                       std::shared_ptr<Logger> logger) {
  namespace fs = std::filesystem;

  std::vector<TransferFunctionInfo> transferFunctions;
  std::error_code ec;
  if (!fs::exists(directory, ec) || !fs::is_directory(directory, ec)) {
    return transferFunctions;
  }

  for (const auto& entry : fs::directory_iterator(directory, ec)) {
    if (ec) break;
    if (!entry.is_regular_file(ec)) continue;

    const auto path = entry.path();
    if (path.extension() != ".tf1d") continue;

    TransferFunctionInfo info;
    std::string reason;
    const std::string filename = path.string();
    if (parseTransferFunctionFile(filename, info, reason)) {
      transferFunctions.push_back(std::move(info));
    } else if (logger) {
      logger->warning("Unable to load transfer function file " + filename + ": " + reason);
    }
  }

  return transferFunctions;
}

static std::string formatUuid(const uint8_t* bytes) {
  std::ostringstream stream;
  stream << std::hex << std::setfill('0');
  for (size_t index = 0; index < 16; ++index) {
    if (index == 4 || index == 6 || index == 8 || index == 10) stream << '-';
    stream << std::setw(2) << static_cast<unsigned int>(bytes[index]);
  }
  return stream.str();
}

static std::vector<MarkerFileInfo> scanMarkerDirectory(const std::string& directory,
                                                       std::shared_ptr<Logger> logger) {
  namespace fs = std::filesystem;
  std::vector<MarkerFileInfo> markerFiles;
  std::error_code ec;
  if (!fs::exists(directory, ec) || !fs::is_directory(directory, ec)) return markerFiles;

  for (const auto& entry : fs::directory_iterator(directory, ec)) {
    if (ec) break;
    if (!entry.is_regular_file(ec) || entry.path().extension() != ".marker") continue;
    const auto byteCount = entry.file_size(ec);
    if (ec || byteCount == 0 || byteCount > BorgVRFormat::kMaximumMarkerFileBytes) continue;
    std::ifstream file(entry.path(), std::ios::binary);
    std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(file)),
                               std::istreambuf_iterator<char>());
    if (bytes.size() != byteCount || bytes.size() > BorgVRFormat::kMaximumMarkerFileBytes) continue;
    const bool validMagic = bytes.size() >= BorgVRFormat::kMarkerHeaderBytes &&
      std::equal(BorgVRFormat::kMarkerMagic.begin(), BorgVRFormat::kMarkerMagic.end(), bytes.begin());
    const uint16_t version = validMagic
      ? static_cast<uint16_t>(bytes[8] | (static_cast<uint16_t>(bytes[9]) << 8))
      : 0;
    const uint32_t markerCount = validMagic
      ? static_cast<uint32_t>(bytes[28]) |
        (static_cast<uint32_t>(bytes[29]) << 8) |
        (static_cast<uint32_t>(bytes[30]) << 16) |
        (static_cast<uint32_t>(bytes[31]) << 24)
      : 0;
    if (!validMagic ||
        version != BorgVRFormat::kMarkerVersion ||
        markerCount > BorgVRFormat::kMaximumMarkerCount) {
      if (logger) logger->warning("Unable to load marker file " + entry.path().string() + ": invalid header");
      continue;
    }
    const std::string datasetId = formatUuid(bytes.data() + 12);
    MarkerFileInfo info;
    info.id = md5Hex(bytes.data(), bytes.size());
    info.filename = entry.path().string();
    info.datasetId = datasetId;
    info.markerDescription = entry.path().stem().string();
    info.byteCount = bytes.size();
    markerFiles.push_back(std::move(info));
  }
  return markerFiles;
}

static std::vector<MeshFileInfo> scanMeshDirectory(const std::string& directory,
                                                   std::shared_ptr<Logger> logger) {
  namespace fs = std::filesystem;
  std::vector<MeshFileInfo> meshes;
  std::error_code ec;
  if (!fs::exists(directory, ec) || !fs::is_directory(directory, ec)) return meshes;

  for (const auto& entry : fs::directory_iterator(directory, ec)) {
    if (ec) break;
    if (!entry.is_regular_file(ec) || entry.path().extension() != ".mesh") continue;
    const auto byteCount = entry.file_size(ec);
    if (ec || byteCount < 32 || byteCount > BorgVRFormat::kMaximumMeshFileBytes) continue;
    std::ifstream file(entry.path(), std::ios::binary);
    std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(file)),
                               std::istreambuf_iterator<char>());
    const bool validMagic = bytes.size() == byteCount && bytes.size() >= 32 &&
      std::equal(BorgVRFormat::kMeshMagic.begin(), BorgVRFormat::kMeshMagic.end(), bytes.begin());
    const uint16_t version = validMagic
      ? static_cast<uint16_t>(bytes[8] | (static_cast<uint16_t>(bytes[9]) << 8))
      : 0;
    const uint16_t nameBytes = validMagic
      ? static_cast<uint16_t>(bytes[28] | (static_cast<uint16_t>(bytes[29]) << 8))
      : 0;
    const uint16_t descriptionBytes = validMagic
      ? static_cast<uint16_t>(bytes[30] | (static_cast<uint16_t>(bytes[31]) << 8))
      : 0;
    if (!validMagic || version != BorgVRFormat::kMeshVersion ||
        nameBytes > BorgVRFormat::kMaximumMeshNameBytes ||
        descriptionBytes > BorgVRFormat::kMaximumMeshDescriptionBytes ||
        32u + static_cast<size_t>(nameBytes) + static_cast<size_t>(descriptionBytes) > bytes.size()) {
      if (logger) logger->warning("Unable to load mesh file " + entry.path().string() + ": invalid header");
      continue;
    }
    MeshFileInfo info;
    info.id = formatUuid(bytes.data() + 12);
    info.filename = entry.path().string();
    info.name.assign(reinterpret_cast<const char*>(bytes.data() + 32), nameBytes);
    info.description.assign(
      reinterpret_cast<const char*>(bytes.data() + 32 + nameBytes),
      descriptionBytes
    );
    if (info.name.empty()) info.name = entry.path().stem().string();
    info.byteCount = bytes.size();
    meshes.push_back(std::move(info));
  }
  return meshes;
}

enum class ArgumentParseResult {
  Run,
  ExitSuccess,
  ExitFailure
};

static bool requireArgumentValue(int argc,
                                 char** argv,
                                 int& index,
                                 const std::string& option,
                                 std::string& value,
                                 const std::shared_ptr<Logger>& logger) {
  if (index + 1 >= argc) {
    logger->error("Missing value for " + option + ".");
    return false;
  }
  value = argv[++index];
  return true;
}

static ArgumentParseResult parseArguments(int argc,
                                          char** argv,
                                          ServerConfiguration& configuration,
                                          const std::shared_ptr<Logger>& logger) {
  configuration.datasetDirectory = defaultDatasetDirectory();

  for (int index = 1; index < argc; ++index) {
    const std::string option = argv[index];
    std::string value;
    if (option == "--directory" || option == "-d") {
      if (!requireArgumentValue(argc, argv, index, option, value, logger)) {
        return ArgumentParseResult::ExitFailure;
      }
      configuration.datasetDirectory = value;
    } else if (option == "--port" || option == "-p") {
      if (!requireArgumentValue(argc, argv, index, option, value, logger)) {
        return ArgumentParseResult::ExitFailure;
      }
      if (!parseUint16(value, configuration.port)) {
        logger->error("Invalid port: " + value);
        return ArgumentParseResult::ExitFailure;
      }
    } else if (option == "--max-bricks" || option == "-m") {
      if (!requireArgumentValue(argc, argv, index, option, value, logger)) {
        return ArgumentParseResult::ExitFailure;
      }
      if (!parseInt(value, configuration.maxBricksPerGetRequest) ||
          configuration.maxBricksPerGetRequest <= 0) {
        logger->error("Invalid max-bricks value: " + value);
        return ArgumentParseResult::ExitFailure;
      }
    } else if (option == "--password") {
      if (!requireArgumentValue(argc, argv, index, option, configuration.password, logger)) {
        return ArgumentParseResult::ExitFailure;
      }
    } else if (option == "--scan-interval") {
      if (!requireArgumentValue(argc, argv, index, option, value, logger)) {
        return ArgumentParseResult::ExitFailure;
      }
      if (!parseInt(value, configuration.scanIntervalSeconds) ||
          configuration.scanIntervalSeconds < 0) {
        logger->error("Invalid scan interval: " + value);
        return ArgumentParseResult::ExitFailure;
      }
    } else if (option == "--web-port") {
      if (!requireArgumentValue(argc, argv, index, option, value, logger)) {
        return ArgumentParseResult::ExitFailure;
      }
      if (!parseUint16(value, configuration.webPort)) {
        logger->error("Invalid WebGPU port: " + value);
        return ArgumentParseResult::ExitFailure;
      }
    } else if (option == "--log-file") {
      if (!requireArgumentValue(argc, argv, index, option, configuration.logFile, logger)) {
        return ArgumentParseResult::ExitFailure;
      }
      if (configuration.logFile.empty()) {
        logger->error("Log file path must not be empty.");
        return ArgumentParseResult::ExitFailure;
      }
    } else if (option == "--sync-server") {
      ServerSyncEndpoint endpoint;
      if (!requireArgumentValue(argc, argv, index, option, endpoint.address, logger) ||
          !requireArgumentValue(argc, argv, index, option, value, logger)) {
        return ArgumentParseResult::ExitFailure;
      }
      if (!parseUint16(value, endpoint.port)) {
        logger->error("Invalid sync server port: " + value);
        return ArgumentParseResult::ExitFailure;
      }
      if (!requireArgumentValue(argc, argv, index, option, value, logger)) {
        return ArgumentParseResult::ExitFailure;
      }
      if (!parseInt(value, endpoint.intervalSeconds) || endpoint.intervalSeconds < 10) {
        logger->error("Invalid sync server interval: " + value);
        return ArgumentParseResult::ExitFailure;
      }
      if (index + 1 < argc && std::string(argv[index + 1]).rfind("-", 0) != 0) {
        endpoint.password = argv[++index];
      }
      if (!endpoint.usable()) {
        logger->error("Invalid sync server configuration.");
        return ArgumentParseResult::ExitFailure;
      }
      configuration.syncServers.push_back(std::move(endpoint));
    } else if (option == "--version" || option == "-v") {
      std::cout << BORGVR_SERVER_VERSION << "\n";
      return ArgumentParseResult::ExitSuccess;
    } else if (option == "--help" || option == "-h") {
      printUsage(argv[0]);
      return ArgumentParseResult::ExitSuccess;
    } else {
      logger->error("Unknown argument: " + option);
      return ArgumentParseResult::ExitFailure;
    }
  }
  return ArgumentParseResult::Run;
}

static std::string datasetDisplayName(const DatasetInfo& dataset) {
  if (!dataset.datasetDescription.empty()) return dataset.datasetDescription;
  return std::filesystem::path(dataset.filename).stem().string();
}

static void printDatasets(const std::vector<DatasetInfo>& datasets) {
  if (datasets.empty()) {
    std::cout << "No datasets are currently available.\n" << std::flush;
    return;
  }

  std::cout << "Available datasets (" << datasets.size() << "):\n";
  for (size_t index = 0; index < datasets.size(); ++index) {
    const auto& dataset = datasets[index];
    std::cout << "  " << index + 1 << ". " << datasetDisplayName(dataset) << "\n"
              << "     ID      : " << dataset.id << "\n"
              << "     Voxels  : " << dataset.width << " x " << dataset.height << " x "
              << dataset.depth << "\n"
              << "     Size    : " << std::setprecision(6)
              << dataset.width * static_cast<double>(dataset.voxelSpacingX) << " x "
              << dataset.height * static_cast<double>(dataset.voxelSpacingY) << " x "
              << dataset.depth * static_cast<double>(dataset.voxelSpacingZ) << " m\n";
  }
  std::cout << std::flush;
}

static void printConsoleHelp() {
  std::cout
    << "Commands:\n"
    << "  l  List currently available datasets.\n"
    << "  l0 Log developer/debug messages and above.\n"
    << "  l1 Log informational messages and above.\n"
    << "  l2 Log warnings and errors.\n"
    << "  l3 Log errors only.\n"
    << "  r  Refresh the server catalog now.\n"
    << "  h  Show this command list.\n"
    << "  q  Stop the server and quit.\n"
    << std::flush;
}

int main(int argc, char** argv) {
  SocketSystem sockSys;
  auto logger = std::make_shared<Logger>(LogLevel::Info);

  ServerConfiguration configuration;
  const auto parseResult = parseArguments(argc, argv, configuration, logger);
  if (parseResult != ArgumentParseResult::Run) {
    if (parseResult == ArgumentParseResult::ExitFailure) printUsage(argv[0]);
    return parseResult == ArgumentParseResult::ExitSuccess ? 0 : 2;
  }

  std::error_code directoryError;
  if (!std::filesystem::is_directory(configuration.datasetDirectory, directoryError)) {
    logger->error("Dataset directory does not exist: " + configuration.datasetDirectory);
    return 2;
  }
  if (!configuration.logFile.empty() && !logger->setLogFile(configuration.logFile)) {
    logger->error("Unable to open log file: " + configuration.logFile);
    return 2;
  }

  printStartupBanner(configuration);

  auto datasets = scanDatasetDirectory(configuration.datasetDirectory, logger);
  auto transferFunctions = scanTransferFunctionDirectory(configuration.datasetDirectory, logger);
  auto markerFiles = scanMarkerDirectory(configuration.datasetDirectory, logger);
  auto meshFiles = scanMeshDirectory(configuration.datasetDirectory, logger);

  TCPServer server(
    configuration.port,
    configuration.maxBricksPerGetRequest,
    logger,
    configuration.password
  );
  server.setDatasets(datasets);
  server.setTransferFunctions(transferFunctions);
  server.setMarkerFiles(markerFiles);
  server.setMeshFiles(meshFiles);
  if (!server.start()) {
    return 2;
  }

  std::unique_ptr<HTTPWebServer> webServer;
  if (configuration.webPort > 0) {
    webServer = std::make_unique<HTTPWebServer>(
      configuration.webPort,
      server,
      logger,
      configuration.password
    );
    if (!webServer->start()) {
      server.stop();
      return 3;
    }
  }

  auto refreshCatalog = [&]() {
    const auto refreshed = scanDatasetDirectory(configuration.datasetDirectory, logger);
    server.setDatasets(refreshed);
    const auto refreshedTransferFunctions = scanTransferFunctionDirectory(
      configuration.datasetDirectory,
      logger
    );
    server.setTransferFunctions(refreshedTransferFunctions);
    server.setMarkerFiles(scanMarkerDirectory(configuration.datasetDirectory, logger));
    server.setMeshFiles(scanMeshDirectory(configuration.datasetDirectory, logger));
  };

  std::unique_ptr<ServerSyncManager> syncManager;
  if (!configuration.syncServers.empty()) {
    auto localDatasetIds = [&]() {
      std::unordered_set<std::string> ids;
      for (const auto& dataset : scanDatasetDirectory(configuration.datasetDirectory, nullptr)) {
        ids.insert(dataset.id);
      }
      return ids;
    };
    auto localTransferFunctionIds = [&]() {
      std::unordered_set<std::string> ids;
      for (const auto& tf : scanTransferFunctionDirectory(configuration.datasetDirectory, nullptr)) {
        ids.insert(tf.id);
      }
      return ids;
    };
    auto localMeshIds = [&]() {
      std::unordered_set<std::string> ids;
      for (const auto& mesh : scanMeshDirectory(configuration.datasetDirectory, nullptr)) {
        ids.insert(mesh.id);
      }
      return ids;
    };

    syncManager = std::make_unique<ServerSyncManager>(
      configuration.datasetDirectory,
      configuration.syncServers,
      localDatasetIds,
      localTransferFunctionIds,
      localMeshIds,
      refreshCatalog,
      logger
    );
    syncManager->start();
  }

  std::atomic<bool> monitorRunning{true};
  std::thread monitorThread;
  if (configuration.scanIntervalSeconds > 0) {
    monitorThread = std::thread([&]() {
      while (monitorRunning.load()) {
        for (int i = 0;
             i < configuration.scanIntervalSeconds * 10 && monitorRunning.load();
             ++i) {
          std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
        if (monitorRunning.load()) refreshCatalog();
      }
    });
  }

  printConsoleHelp();

  std::string line;
  while (std::getline(std::cin, line)) {
    const std::string command = trimCopy(line);
    if (command == "q" || command == "Q") {
      break;
    } else if (command == "l" || command == "L") {
      printDatasets(server.datasetsSnapshot());
    } else if (command == "l0" || command == "L0") {
      logger->setMinLevel(LogLevel::Debug);
      std::cout << "Log level set to developer/debug (l0).\n" << std::flush;
    } else if (command == "l1" || command == "L1") {
      logger->setMinLevel(LogLevel::Info);
      std::cout << "Log level set to info (l1).\n" << std::flush;
    } else if (command == "l2" || command == "L2") {
      logger->setMinLevel(LogLevel::Warning);
      std::cout << "Log level set to warning (l2).\n" << std::flush;
    } else if (command == "l3" || command == "L3") {
      logger->setMinLevel(LogLevel::Error);
      std::cout << "Log level set to error (l3).\n" << std::flush;
    } else if (command == "r" || command == "R") {
      refreshCatalog();
      logger->info("Server catalog refreshed.");
    } else if (command == "h" || command == "H" || command == "?") {
      printConsoleHelp();
    } else if (!command.empty()) {
      logger->warning("Unknown command: " + command + ". Type 'h' for help.");
    }
  }

  monitorRunning = false;
  if (monitorThread.joinable()) {
    monitorThread.join();
  }
  if (webServer) {
    webServer->stop();
  }
  if (syncManager) {
    syncManager->stop();
  }
  server.stop();

  return 0;
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
