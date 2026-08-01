#include "BORGVRMetaData.h"
#include "BinaryIO.h"
#include "BORGVRDataBase.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <fstream>
#include <stdexcept>

static constexpr const char* kMagic = "BORGVR";
static constexpr size_t kMagicLen = 6;

BORGVRMetaData::BORGVRMetaData(const std::string& filename) {
  loadFromFile(filename);
}

void BORGVRMetaData::loadFromFile(const std::string& filename) {
  std::ifstream f(filename, std::ios::binary);
  if (!f) {
    throw BorgVRException(BorgVRDataErrorCode::IoError, "Failed to open file: " + filename);
  }

  uint8_t offBytes[8]{};
  f.read(reinterpret_cast<char*>(offBytes), 8);
  if (f.gcount() != 8) {
    throw BorgVRException(BorgVRDataErrorCode::IoError, "Failed to read metadata offset (8 bytes).");
  }

  const uint64_t metaOffset = read_u64_le(offBytes);

  f.seekg(0, std::ios::end);
  const std::streamoff fileSize = f.tellg();
  if (fileSize <= 0) {
    throw BorgVRException(BorgVRDataErrorCode::IoError, "Invalid file size.");
  }
  if (static_cast<uint64_t>(fileSize) < metaOffset) {
    throw BorgVRException(BorgVRDataErrorCode::IoError, "Metadata offset beyond end of file.");
  }

  const size_t metaSize = static_cast<size_t>(fileSize - static_cast<std::streamoff>(metaOffset));
  std::vector<uint8_t> meta(metaSize);

  f.seekg(static_cast<std::streamoff>(metaOffset), std::ios::beg);
  f.read(reinterpret_cast<char*>(meta.data()), static_cast<std::streamsize>(metaSize));
  if (static_cast<size_t>(f.gcount()) != metaSize) {
    throw BorgVRException(BorgVRDataErrorCode::IoError, "Failed to read metadata section.");
  }

  parseFromBytes(meta.data(), meta.size());
}

void BORGVRMetaData::parseFromBytes(const uint8_t* data, size_t size) {
  if (!data || size < kMagicLen) {
    throw BorgVRException(BorgVRDataErrorCode::InvalidArgument, "Metadata buffer too small.");
  }
  if (std::memcmp(data, kMagic, kMagicLen) != 0) {
    throw BorgVRException(BorgVRDataErrorCode::InvalidArgument, "Invalid magic bytes in BORGVR metadata.");
  }

  BinaryReader br(data + kMagicLen, size - kMagicLen);

  const int64_t fileVersion = br.read_i64("version");
  if (fileVersion != kVersion) {
    throw BorgVRException(BorgVRDataErrorCode::InvalidArgument,
                          "Unsupported metadata version " + std::to_string(fileVersion) +
                          " (expected " + std::to_string(kVersion) + ")");
  }

  width_ = static_cast<int>(br.read_i64("width"));
  height_ = static_cast<int>(br.read_i64("height"));
  depth_ = static_cast<int>(br.read_i64("depth"));

  componentCount_ = static_cast<int>(br.read_i64("componentCount"));
  bytesPerComponent_ = static_cast<int>(br.read_i64("bytesPerComponent"));

  aspectX_ = br.read_f32("aspectX");
  aspectY_ = br.read_f32("aspectY");
  aspectZ_ = br.read_f32("aspectZ");

  brickSize_ = static_cast<int>(br.read_i64("brickSize"));
  overlap_ = static_cast<int>(br.read_i64("overlap"));
  minValue_ = static_cast<int>(br.read_i64("minValue"));
  maxValue_ = static_cast<int>(br.read_i64("maxValue"));

  compression_ = br.read_bool("compression");

  uniqueID_ = br.read_string("uniqueID");
  datasetDescription_ = br.read_string("datasetDescription");
  metaDescription_ = br.read_string("metaDescription");

  const int64_t metadataCount64 = br.read_i64("brickMetadataCount");
  const int64_t dataOffset64 = br.read_i64("brickDataOffset");
  if (metadataCount64 < 0 || dataOffset64 < 0) {
    throw BorgVRException(BorgVRDataErrorCode::InvalidArgument, "Negative brick metadata count/dataOffset.");
  }

  computeLevelMetadata();

  if (dataOffset64 > 0) {
    br.skip(static_cast<size_t>(dataOffset64), "brickDataOffset");
  }

  const size_t metadataCount = static_cast<size_t>(metadataCount64);
  brickMetadata_.clear();
  brickMetadata_.reserve(metadataCount);

  for (size_t i = 0; i < metadataCount; ++i) {
    BrickMetadata bm;
    bm.offset = br.read_i64("brick offset");
    bm.size = br.read_i64("brick size");
    bm.minValue = br.read_i64("brick minValue");
    bm.maxValue = br.read_i64("brick maxValue");
    brickMetadata_.push_back(bm);
  }
}

std::vector<uint8_t> BORGVRMetaData::toBytes() const {
  std::vector<uint8_t> out;
  out.reserve(1024 + brickMetadata_.size() * 32);

  append_bytes(out, reinterpret_cast<const uint8_t*>(kMagic), kMagicLen);

  append_i64_le(out, static_cast<int64_t>(kVersion));
  append_i64_le(out, static_cast<int64_t>(width_));
  append_i64_le(out, static_cast<int64_t>(height_));
  append_i64_le(out, static_cast<int64_t>(depth_));

  append_i64_le(out, static_cast<int64_t>(componentCount_));
  append_i64_le(out, static_cast<int64_t>(bytesPerComponent_));

  append_f32_le(out, aspectX_);
  append_f32_le(out, aspectY_);
  append_f32_le(out, aspectZ_);

  append_i64_le(out, static_cast<int64_t>(brickSize_));
  append_i64_le(out, static_cast<int64_t>(overlap_));
  append_i64_le(out, static_cast<int64_t>(minValue_));
  append_i64_le(out, static_cast<int64_t>(maxValue_));

  append_bool(out, compression_);

  append_string(out, uniqueID_);
  append_string(out, datasetDescription_);
  append_string(out, metaDescription_);

  append_i64_le(out, static_cast<int64_t>(brickMetadata_.size()));

  // Swift toData() uses a dataOffset placeholder of 0.
  append_i64_le(out, static_cast<int64_t>(0));

  for (const auto& b : brickMetadata_) {
    append_i64_le(out, b.offset);
    append_i64_le(out, b.size);
    append_i64_le(out, b.minValue);
    append_i64_le(out, b.maxValue);
  }

  return out;
}

const BrickMetadata& BORGVRMetaData::getBrickMetadata(int level, int x, int y, int z) const {
  const auto& levelMeta = levelMetadata_.at(static_cast<size_t>(level));
  const int index = levelMeta.prevBricks
                  + x
                  + y * levelMeta.totalBricks.x
                  + z * levelMeta.totalBricks.x * levelMeta.totalBricks.y;
  return brickMetadata_.at(static_cast<size_t>(index));
}

Vec3<int> BORGVRMetaData::calculateOutputBrickCount(Vec3<int> size, int brickSize, int overlap) {
  const int effectiveSize = brickSize - 2 * overlap;
  Vec3<int> out{};
  out.x = (size.x + effectiveSize - 1) / effectiveSize;
  out.y = (size.y + effectiveSize - 1) / effectiveSize;
  out.z = (size.z + effectiveSize - 1) / effectiveSize;
  return out;
}

int BORGVRMetaData::calculateLevelCount(Vec3<int> size, int brickSize, int overlap) {
  const auto brickCount = calculateOutputBrickCount(size, brickSize, overlap);
  const int m = std::max({brickCount.x, brickCount.y, brickCount.z});
  if (m <= 1) return 1;
  return 1 + static_cast<int>(std::ceil(std::log2(static_cast<double>(m))));
}

void BORGVRMetaData::computeLevelMetadata() {
  levelMetadata_.clear();

  Vec3<int> size{width_, height_, depth_};
  const int levelCount = calculateLevelCount(size, brickSize_, overlap_);

  int levelWidth = width_;
  int levelHeight = height_;
  int levelDepth = depth_;
  int prevBricks = 0;

  for (int lvl = 0; lvl < levelCount; ++lvl) {
    LevelMetadata lm;
    lm.size = Vec3<int>{levelWidth, levelHeight, levelDepth};
    lm.prevBricks = prevBricks;
    lm.totalBricks = calculateOutputBrickCount(lm.size, brickSize_, overlap_);

    levelMetadata_.push_back(lm);

    levelWidth /= 2;
    levelHeight /= 2;
    levelDepth /= 2;

    prevBricks += lm.totalBricks.x * lm.totalBricks.y * lm.totalBricks.z;
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
