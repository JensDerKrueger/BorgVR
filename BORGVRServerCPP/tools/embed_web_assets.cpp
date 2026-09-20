#include "LZ4.h"

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>

namespace fs = std::filesystem;

namespace {

constexpr const char* kCopyrightBlock = R"COPYRIGHT(
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
)COPYRIGHT";

struct Asset {
  std::string route;
  std::string contentType;
  std::vector<uint8_t> storedData;
  size_t uncompressedSize = 0;
  bool compressed = false;
};

std::string lowerExtension(const fs::path& path) {
  std::string extension = path.extension().string();
  std::transform(extension.begin(), extension.end(), extension.begin(), [](unsigned char character) {
    return static_cast<char>(std::tolower(character));
  });
  return extension;
}

std::string contentTypeFor(const fs::path& path) {
  static const std::unordered_map<std::string, std::string> contentTypes = {
    {".html", "text/html; charset=utf-8"},
    {".css", "text/css; charset=utf-8"},
    {".js", "text/javascript; charset=utf-8"},
    {".json", "application/json; charset=utf-8"},
    {".jpg", "image/jpeg"},
    {".jpeg", "image/jpeg"},
    {".png", "image/png"},
    {".svg", "image/svg+xml"},
    {".ico", "image/x-icon"},
  };
  const auto found = contentTypes.find(lowerExtension(path));
  return found == contentTypes.end() ? "application/octet-stream" : found->second;
}

std::vector<uint8_t> readFile(const fs::path& path) {
  std::ifstream input(path, std::ios::binary | std::ios::ate);
  if (!input) {
    throw std::runtime_error("Unable to open " + path.string());
  }
  const std::streamoff length = input.tellg();
  if (length < 0) {
    throw std::runtime_error("Unable to determine the size of " + path.string());
  }
  std::vector<uint8_t> data(static_cast<size_t>(length));
  input.seekg(0, std::ios::beg);
  if (!data.empty() && !input.read(reinterpret_cast<char*>(data.data()), length)) {
    throw std::runtime_error("Unable to read " + path.string());
  }
  return data;
}

Asset loadAsset(const fs::path& webDirectory, const fs::path& path) {
  Asset asset;
  const fs::path relative = fs::relative(path, webDirectory);
  asset.route = "/" + relative.generic_string();
  asset.contentType = contentTypeFor(path);

  std::vector<uint8_t> source = readFile(path);
  asset.uncompressedSize = source.size();
  asset.storedData = source;

  if (source.size() >= 4) {
    std::vector<uint8_t> compressed(lz4::compressBlockBound(source.size()));
    const size_t compressedSize = lz4::compressBlock(
      source.data(), source.size(), compressed.data(), compressed.size()
    );
    if (compressedSize > 0 && compressedSize < source.size()) {
      compressed.resize(compressedSize);

      std::vector<uint8_t> verification(source.size());
      const size_t decodedSize = lz4::decompressBlock(
        compressed.data(), compressed.size(), verification.data(), verification.size()
      );
      if (decodedSize != source.size() || verification != source) {
        throw std::runtime_error("LZ4 verification failed for " + path.string());
      }

      asset.storedData = std::move(compressed);
      asset.compressed = true;
    }
  }

  return asset;
}

std::string cppString(const std::string& text) {
  std::ostringstream output;
  output << '"';
  for (unsigned char character : text) {
    switch (character) {
      case '\\': output << "\\\\"; break;
      case '"': output << "\\\""; break;
      case '\n': output << "\\n"; break;
      case '\r': output << "\\r"; break;
      case '\t': output << "\\t"; break;
      default:
        if (character < 0x20 || character == 0x7f) {
          output << "\\x" << std::hex << std::setw(2) << std::setfill('0')
                 << static_cast<int>(character) << std::dec << "\"\"";
        } else {
          output << static_cast<char>(character);
        }
        break;
    }
  }
  output << '"';
  return output.str();
}

void appendByteArray(std::ostringstream& output, const std::vector<uint8_t>& data) {
  if (data.empty()) {
    output << "  0x00\n";
    return;
  }
  output << std::hex << std::setfill('0');
  for (size_t index = 0; index < data.size(); ++index) {
    if (index % 16 == 0) output << "  ";
    output << "0x" << std::setw(2) << static_cast<unsigned int>(data[index]);
    if (index + 1 < data.size()) output << ", ";
    if (index % 16 == 15 || index + 1 == data.size()) output << '\n';
  }
  output << std::dec;
}

std::string generateHeader() {
  std::ostringstream output;
  output << "#pragma once\n\n"
         << "#include <cstddef>\n"
         << "#include <cstdint>\n\n"
         << "enum class EmbeddedWebAssetEncoding : uint8_t {\n"
         << "  raw,\n"
         << "  lz4\n"
         << "};\n\n"
         << "struct EmbeddedWebAsset {\n"
         << "  const char* path;\n"
         << "  const char* contentType;\n"
         << "  const uint8_t* data;\n"
         << "  size_t storedSize;\n"
         << "  size_t uncompressedSize;\n"
         << "  EmbeddedWebAssetEncoding encoding;\n"
         << "};\n\n"
         << "const EmbeddedWebAsset* findEmbeddedWebAsset(const char* path);\n"
         << "const EmbeddedWebAsset* embeddedWebAssets();\n"
         << "size_t embeddedWebAssetCount();\n"
         << kCopyrightBlock;
  return output.str();
}

std::string generateSource(const std::vector<Asset>& assets) {
  std::ostringstream output;
  output << "#include \"GeneratedWebAssets.h\"\n\n"
         << "#include <cstring>\n\n"
         << "namespace {\n\n";

  for (size_t index = 0; index < assets.size(); ++index) {
    output << "const uint8_t kWebAsset_" << index << "[] = {\n";
    appendByteArray(output, assets[index].storedData);
    output << "};\n\n";
  }

  output << "const EmbeddedWebAsset kEmbeddedWebAssets[] = {\n";
  for (size_t index = 0; index < assets.size(); ++index) {
    const Asset& asset = assets[index];
    output << "  {" << cppString(asset.route) << ", " << cppString(asset.contentType)
           << ", kWebAsset_" << index << ", " << asset.storedData.size() << ", "
           << asset.uncompressedSize << ", EmbeddedWebAssetEncoding::"
           << (asset.compressed ? "lz4" : "raw") << "},\n";
  }
  output << "};\n\n"
         << "} // namespace\n\n"
         << "const EmbeddedWebAsset* findEmbeddedWebAsset(const char* path) {\n"
         << "  if (!path) return nullptr;\n"
         << "  const char* lookupPath = (std::strcmp(path, \"/\") == 0) ? \"/index.html\" : path;\n"
         << "  for (const auto& asset : kEmbeddedWebAssets) {\n"
         << "    if (std::strcmp(asset.path, lookupPath) == 0) return &asset;\n"
         << "  }\n"
         << "  return nullptr;\n"
         << "}\n\n"
         << "const EmbeddedWebAsset* embeddedWebAssets() {\n"
         << "  return kEmbeddedWebAssets;\n"
         << "}\n\n"
         << "size_t embeddedWebAssetCount() {\n"
         << "  return sizeof(kEmbeddedWebAssets) / sizeof(kEmbeddedWebAssets[0]);\n"
         << "}\n"
         << kCopyrightBlock;
  return output.str();
}

void writeIfChanged(const fs::path& path, const std::string& contents) {
  if (fs::exists(path)) {
    std::ifstream current(path, std::ios::binary);
    const std::string existing(
      (std::istreambuf_iterator<char>(current)), std::istreambuf_iterator<char>()
    );
    if (existing == contents) return;
  }

  fs::create_directories(path.parent_path());
  const fs::path temporary = path.string() + ".tmp";
  {
    std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
    if (!output || !output.write(contents.data(), static_cast<std::streamsize>(contents.size()))) {
      throw std::runtime_error("Unable to write " + temporary.string());
    }
  }

  std::error_code error;
  fs::rename(temporary, path, error);
  if (error) {
    fs::remove(path, error);
    error.clear();
    fs::rename(temporary, path, error);
  }
  if (error) {
    fs::remove(temporary);
    throw std::runtime_error("Unable to replace " + path.string() + ": " + error.message());
  }
}

fs::path argumentValue(int argc, char** argv, const std::string& name) {
  for (int index = 1; index + 1 < argc; ++index) {
    if (argv[index] == name) return argv[index + 1];
  }
  throw std::runtime_error("Missing required argument " + name);
}

} // namespace

int main(int argc, char** argv) {
  try {
    const fs::path webDirectory = fs::absolute(argumentValue(argc, argv, "--web-dir"));
    const fs::path outputDirectory = fs::absolute(argumentValue(argc, argv, "--out-dir"));
    if (!fs::is_directory(webDirectory)) {
      throw std::runtime_error("Web directory does not exist: " + webDirectory.string());
    }

    std::vector<fs::path> paths;
    for (const auto& entry : fs::recursive_directory_iterator(webDirectory)) {
      if (entry.is_regular_file() && entry.path().filename().string().front() != '.') {
        paths.push_back(entry.path());
      }
    }
    std::sort(paths.begin(), paths.end(), [&](const fs::path& lhs, const fs::path& rhs) {
      return fs::relative(lhs, webDirectory).generic_string() <
             fs::relative(rhs, webDirectory).generic_string();
    });
    if (paths.empty()) {
      throw std::runtime_error("Web directory contains no assets: " + webDirectory.string());
    }

    std::vector<Asset> assets;
    assets.reserve(paths.size());
    size_t sourceBytes = 0;
    size_t storedBytes = 0;
    for (const fs::path& path : paths) {
      Asset asset = loadAsset(webDirectory, path);
      sourceBytes += asset.uncompressedSize;
      storedBytes += asset.storedData.size();
      assets.push_back(std::move(asset));
    }

    writeIfChanged(outputDirectory / "GeneratedWebAssets.h", generateHeader());
    writeIfChanged(outputDirectory / "GeneratedWebAssets.cpp", generateSource(assets));
    std::cout << "Embedded " << assets.size() << " web assets (" << sourceBytes
              << " bytes -> " << storedBytes << " stored bytes).\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "Web asset generation failed: " << error.what() << '\n';
    return 1;
  }
}
