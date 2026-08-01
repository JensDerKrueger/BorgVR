#pragma once

#include <cstdint>
#include <string>
#include <vector>

template <typename T>
struct Vec3 {
  T x{};
  T y{};
  T z{};
};

struct BrickMetadata {
  int64_t offset = 0;  // absolute byte offset in the dataset file
  int64_t size = 0;    // stored byte size (may be compressed)
  int64_t minValue = 0;
  int64_t maxValue = 0;
};

struct LevelMetadata {
  Vec3<int> size{};
  Vec3<int> totalBricks{};
  int prevBricks = 0;
};

class BORGVRMetaData {
public:
  static constexpr int kVersion = 3;

  BORGVRMetaData() = default;
  explicit BORGVRMetaData(const std::string& filename);

  // Parse metadata from a byte buffer that starts with the "BORGVR" magic bytes.
  void parseFromBytes(const uint8_t* data, size_t size);

  // Load from dataset file: reads first 8 bytes as metadata offset (UInt64 LE) and parses from there.
  void loadFromFile(const std::string& filename);

  // Serialize in the same layout as Swift `BORGVRMetaData.toData()`.
  std::vector<uint8_t> toBytes() const;

  // Accessors
  int width() const { return width_; }
  int height() const { return height_; }
  int depth() const { return depth_; }
  float aspectX() const { return aspectX_; }
  float aspectY() const { return aspectY_; }
  float aspectZ() const { return aspectZ_; }
  int componentCount() const { return componentCount_; }
  int bytesPerComponent() const { return bytesPerComponent_; }
  int brickSize() const { return brickSize_; }
  int overlap() const { return overlap_; }
  int minValue() const { return minValue_; }
  int maxValue() const { return maxValue_; }
  bool compression() const { return compression_; }

  const std::string& uniqueID() const { return uniqueID_; }
  const std::string& datasetDescription() const { return datasetDescription_; }
  const std::string& metaDescription() const { return metaDescription_; }

  const std::vector<LevelMetadata>& levelMetadata() const { return levelMetadata_; }
  const std::vector<BrickMetadata>& brickMetadata() const { return brickMetadata_; }

  const BrickMetadata& getBrickMetadata(int index) const { return brickMetadata_.at(static_cast<size_t>(index)); }

  const BrickMetadata& getBrickMetadata(int level, int x, int y, int z) const;

  static Vec3<int> calculateOutputBrickCount(Vec3<int> size, int brickSize, int overlap);
  static int calculateLevelCount(Vec3<int> size, int brickSize, int overlap);

private:
  void computeLevelMetadata();

  int width_ = 0;
  int height_ = 0;
  int depth_ = 0;

  float aspectX_ = 0.0f;
  float aspectY_ = 0.0f;
  float aspectZ_ = 0.0f;

  int componentCount_ = 0;
  int bytesPerComponent_ = 0;

  int brickSize_ = 0;
  int overlap_ = 0;

  int minValue_ = 0;
  int maxValue_ = 0;

  bool compression_ = false;

  std::string uniqueID_;
  std::string datasetDescription_;
  std::string metaDescription_;

  std::vector<LevelMetadata> levelMetadata_;
  std::vector<BrickMetadata> brickMetadata_;
};

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
