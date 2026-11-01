#include "BORGVRMetaData.h"
#include "BinaryIO.h"
#include "BORGVRDataBase.h"
#include "LZ4.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstring>
#include <fstream>
#include <limits>
#include <stdexcept>

static constexpr const char* kMagic = "BORGVR";
static constexpr size_t kMagicLen = 6;

namespace {
constexpr size_t kMaximumStringLength = 1'048'576;
constexpr int kMaximumComponentCount = 1024;

int checked_int(int64_t value, const char* context) {
  if (value < static_cast<int64_t>(std::numeric_limits<int>::min()) ||
      value > static_cast<int64_t>(std::numeric_limits<int>::max())) {
    throw BorgVRException(BorgVRDataErrorCode::InvalidArgument,
                          std::string("Invalid ") + context + ": value is not representable.");
  }
  return static_cast<int>(value);
}

bool is_valid_uuid(const std::string& value) {
  if (value.size() != 36) return false;
  for (size_t i = 0; i < value.size(); ++i) {
    if (i == 8 || i == 13 || i == 18 || i == 23) {
      if (value[i] != '-') return false;
    } else if (!std::isxdigit(static_cast<unsigned char>(value[i]))) {
      return false;
    }
  }
  return true;
}

bool is_valid_utf8(const std::string& value) {
  const auto* bytes = reinterpret_cast<const uint8_t*>(value.data());
  size_t index = 0;
  while (index < value.size()) {
    const uint8_t first = bytes[index];
    if (first <= 0x7f) {
      ++index;
      continue;
    }

    size_t continuationCount = 0;
    uint8_t secondMinimum = 0x80;
    uint8_t secondMaximum = 0xbf;
    if (first >= 0xc2 && first <= 0xdf) {
      continuationCount = 1;
    } else if (first >= 0xe0 && first <= 0xef) {
      continuationCount = 2;
      if (first == 0xe0) secondMinimum = 0xa0;
      if (first == 0xed) secondMaximum = 0x9f;
    } else if (first >= 0xf0 && first <= 0xf4) {
      continuationCount = 3;
      if (first == 0xf0) secondMinimum = 0x90;
      if (first == 0xf4) secondMaximum = 0x8f;
    } else {
      return false;
    }

    if (continuationCount > value.size() - index - 1) return false;
    const uint8_t second = bytes[index + 1];
    if (second < secondMinimum || second > secondMaximum) return false;
    for (size_t continuation = 2; continuation <= continuationCount; ++continuation) {
      const uint8_t byte = bytes[index + continuation];
      if (byte < 0x80 || byte > 0xbf) return false;
    }
    index += continuationCount + 1;
  }
  return true;
}

void validate_type(ComponentType type, int width) {
  if ((type == ComponentType::FloatingPoint && (width == 4 || width == 8)) ||
      ((type == ComponentType::UnsignedInteger || type == ComponentType::SignedInteger) &&
        (width == 1 || width == 2 || width == 4))) return;
  throw std::runtime_error("Unsupported component type/byte-width combination.");
}

void validate_channel_interpretation(ChannelInterpretation interpretation, ComponentType type,
                                     int width, int componentCount) {
  switch (interpretation) {
    case ChannelInterpretation::IndependentChannels:
      return;
    case ChannelInterpretation::RGB:
    case ChannelInterpretation::RGBA:
      if (type == ComponentType::UnsignedInteger && width == 1 &&
          componentCount == (interpretation == ChannelInterpretation::RGB ? 3 : 4)) return;
      throw std::runtime_error("RGB/RGBA requires unsigned 8-bit components and 3/4 channels respectively.");
    default:
      throw std::runtime_error("Unknown channel interpretation.");
  }
}

void validate_range(ComponentRange range, ComponentType type, int width) {
  const double lo = range.minValue, hi = range.maxValue;
  if (type == ComponentType::FloatingPoint) {
    if (std::isnan(lo) && std::isnan(hi)) return;
    if (!std::isnan(lo) && !std::isnan(hi) && lo <= hi &&
        (width == 8 || (double(float(lo)) == lo && double(float(hi)) == hi))) return;
  } else {
    const bool signedType = type == ComponentType::SignedInteger;
    const double minimum = signedType ? -std::ldexp(1.0, width * 8 - 1) : 0;
    const double maximum = std::ldexp(1.0, width * 8 - (signedType ? 1 : 0)) - 1;
    if (std::isfinite(lo) && std::isfinite(hi) && lo <= hi && lo >= minimum && hi <= maximum &&
        std::trunc(lo) == lo && std::trunc(hi) == hi) return;
  }
  throw std::runtime_error("Invalid typed component range.");
}

ComponentRange read_range(BinaryReader& br, ComponentType type, int width) {
  auto read = [&]() -> double {
    uint64_t bits = 0;
    for (int i = 0; i < width; ++i) bits |= uint64_t(br.read_u8("bound")) << (i * 8);
    if (type == ComponentType::UnsignedInteger) return static_cast<double>(bits);
    if (type == ComponentType::SignedInteger) {
      const int count = width * 8;
      return (bits & (uint64_t(1) << (count - 1)))
        ? static_cast<double>(int64_t(bits) - (int64_t(1) << count)) : static_cast<double>(bits);
    }
    if (width == 4) {
      uint32_t small = static_cast<uint32_t>(bits);
      float value;
      std::memcpy(&value, &small, 4);
      return value;
    }
    double value;
    std::memcpy(&value, &bits, 8);
    return value;
  };
  const double lo = read(), hi = read();
  ComponentRange range{lo, hi};
  validate_range(range, type, width);
  return range;
}

void append_range(std::vector<uint8_t>& out, ComponentRange range, ComponentType type, int width) {
  validate_range(range, type, width);
  for (double value : {range.minValue, range.maxValue}) {
    uint64_t bits;
    if (type == ComponentType::UnsignedInteger) bits = static_cast<uint64_t>(value);
    else if (type == ComponentType::SignedInteger) bits = static_cast<uint64_t>(static_cast<int64_t>(value));
    else if (width == 4) {
      const float small = static_cast<float>(value);
      uint32_t raw;
      std::memcpy(&raw, &small, 4);
      bits = raw;
    } else std::memcpy(&bits, &value, 8);
    for (int i = 0; i < width; ++i) out.push_back(static_cast<uint8_t>(bits >> (i * 8)));
  }
}

void validate_union(ComponentRange range, const std::vector<ComponentRange>& components) {
  double lo = std::numeric_limits<double>::infinity(), hi = -lo;
  for (const auto& c : components) {
    if (std::isnan(c.minValue) || std::isnan(c.maxValue)) {
      if (std::isnan(range.minValue) && std::isnan(range.maxValue)) return;
      throw std::runtime_error("NaN must propagate to the union range.");
    }
    lo = std::min(lo, c.minValue); hi = std::max(hi, c.maxValue);
  }
  if (range.minValue != lo || range.maxValue != hi) throw std::runtime_error("Range is not the union of its component ranges.");
}

constexpr size_t kMaximumTextLength = 67'108'864;
std::vector<uint8_t> read_text_block(BinaryReader& br) {
  const auto codec = br.read_u8("text codec");
  const auto raw = br.read_i64("text decoded size"), stored = br.read_i64("text stored size");
  if (codec > 1 || raw < 0 || stored < 0 || uint64_t(raw) > kMaximumTextLength ||
      uint64_t(stored) > kMaximumTextLength || uint64_t(stored) > br.remaining() ||
      (codec == 0 && raw != stored) || (codec == 1 && (raw == 0 || stored == 0)))
    throw std::runtime_error("Invalid metadata text block.");
  std::vector<uint8_t> input(static_cast<size_t>(stored));
  for (auto& b : input) b = br.read_u8("text payload");
  if (!codec) return input;
  std::vector<uint8_t> output(static_cast<size_t>(raw));
  if (lz4::decompressBlock(input.data(), input.size(), output.data(), output.size()) != output.size())
    throw std::runtime_error("Invalid LZ4 metadata text block.");
  return output;
}

void append_text_block(std::vector<uint8_t>& out, const std::vector<uint8_t>& input) {
  if (input.size() > kMaximumTextLength) throw std::runtime_error("Metadata text block exceeds size limit.");
  std::vector<uint8_t> compressed(lz4::compressBlockBound(input.size()));
  const size_t count = input.empty() ? 0 : lz4::compressBlock(input.data(), input.size(), compressed.data(), compressed.size());
  const bool use = count > 0 && count < input.size();
  out.push_back(use ? 1 : 0);
  append_i64_le(out, static_cast<int64_t>(input.size()));
  append_i64_le(out, static_cast<int64_t>(use ? count : input.size()));
  const auto& payload = use ? compressed : input;
  out.insert(out.end(), payload.begin(), payload.begin() + static_cast<ptrdiff_t>(use ? count : input.size()));
}
}  // namespace

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
  if (metaOffset < 8 || static_cast<uint64_t>(fileSize) <= metaOffset) {
    throw BorgVRException(BorgVRDataErrorCode::IoError,
                          "Metadata offset must point inside the dataset file.");
  }

  const size_t metaSize = static_cast<size_t>(fileSize - static_cast<std::streamoff>(metaOffset));
  std::vector<uint8_t> meta(metaSize);

  f.seekg(static_cast<std::streamoff>(metaOffset), std::ios::beg);
  f.read(reinterpret_cast<char*>(meta.data()), static_cast<std::streamsize>(metaSize));
  if (static_cast<size_t>(f.gcount()) != metaSize) {
    throw BorgVRException(BorgVRDataErrorCode::IoError, "Failed to read metadata section.");
  }

  parseFromBytes(meta.data(), meta.size());

  for (const auto& brick : brickMetadata_) {
    const auto brickEnd = static_cast<uint64_t>(brick.offset) + static_cast<uint64_t>(brick.size);
    if (brickEnd > metaOffset) {
      throw BorgVRException(BorgVRDataErrorCode::InvalidArgument,
                            "Brick data extends into or beyond the metadata section.");
    }
  }
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

  width_ = checked_int(br.read_i64("width"), "width");
  height_ = checked_int(br.read_i64("height"), "height");
  depth_ = checked_int(br.read_i64("depth"), "depth");

  componentCount_ = checked_int(br.read_i64("componentCount"), "componentCount");
  bytesPerComponent_ = checked_int(br.read_i64("bytesPerComponent"), "bytesPerComponent");
  componentType_ = static_cast<ComponentType>(br.read_u8("componentType"));
  channelInterpretation_ = static_cast<ChannelInterpretation>(br.read_u8("channelInterpretation"));
  validate_type(componentType_, bytesPerComponent_);
  validate_channel_interpretation(channelInterpretation_, componentType_, bytesPerComponent_, componentCount_);

  voxelSpacingX_ = br.read_f32("voxelSpacingX");
  voxelSpacingY_ = br.read_f32("voxelSpacingY");
  voxelSpacingZ_ = br.read_f32("voxelSpacingZ");

  brickSize_ = checked_int(br.read_i64("brickSize"), "brickSize");
  overlap_ = checked_int(br.read_i64("overlap"), "overlap");
  const bool scalar = channelInterpretation_ == ChannelInterpretation::IndependentChannels;
  const int rangeCount = scalar ? componentCount_ : (channelInterpretation_ == ChannelInterpretation::RGBA ? 1 : 0);
  ComponentRange datasetRange{0, 0};
  if (scalar) datasetRange = read_range(br, componentType_, bytesPerComponent_);
  minValue_ = datasetRange.minValue;
  maxValue_ = datasetRange.maxValue;

  const int64_t componentRangeCount = scalar ? br.read_i64("componentRangeCount") : rangeCount;
  if (componentCount_ <= 0 || componentCount_ > kMaximumComponentCount || componentRangeCount != rangeCount) {
    throw BorgVRException(BorgVRDataErrorCode::InvalidArgument,
                          "Component range count does not match component count.");
  }
  componentRanges_.clear();
  componentRanges_.reserve(static_cast<size_t>(componentRangeCount));
  for (int64_t component = 0; component < componentRangeCount; ++component) {
    componentRanges_.push_back(read_range(br, componentType_, bytesPerComponent_));
  }
  if (!scalar && !componentRanges_.empty()) datasetRange = componentRanges_.front();
  minValue_ = datasetRange.minValue;
  maxValue_ = datasetRange.maxValue;

  compression_ = br.read_bool("compression");

  if (width_ <= 0 || height_ <= 0 || depth_ <= 0) {
    throw BorgVRException(BorgVRDataErrorCode::InvalidArgument,
                          "Volume dimensions must be greater than zero.");
  }
  if (componentCount_ <= 0 || componentCount_ > kMaximumComponentCount) {
    throw BorgVRException(BorgVRDataErrorCode::InvalidArgument,
                          "Component count is outside the supported range.");
  }
  if (!std::isfinite(voxelSpacingX_) || voxelSpacingX_ <= 0.0f ||
      !std::isfinite(voxelSpacingY_) || voxelSpacingY_ <= 0.0f ||
      !std::isfinite(voxelSpacingZ_) || voxelSpacingZ_ <= 0.0f) {
    throw BorgVRException(BorgVRDataErrorCode::InvalidArgument,
                          "Voxel spacing values must be finite and greater than zero.");
  }
  if (brickSize_ <= 0 || overlap_ < 0 || overlap_ > (brickSize_ - 1) / 2) {
    throw BorgVRException(BorgVRDataErrorCode::InvalidArgument,
                          "Brick size must be greater than twice the overlap.");
  }
  int64_t fullBrickByteCount = 1;
  for (const int factor : {brickSize_, brickSize_, brickSize_, componentCount_, bytesPerComponent_}) {
    if (fullBrickByteCount > std::numeric_limits<int64_t>::max() / factor) {
      throw BorgVRException(BorgVRDataErrorCode::InvalidArgument, "Full brick byte count overflows.");
    }
    fullBrickByteCount *= factor;
  }
  if (rangeCount > 0) validate_union(datasetRange, componentRanges_);

  uniqueID_ = br.read_string("uniqueID", kMaximumStringLength);
  datasetDescription_ = br.read_string("datasetDescription", kMaximumStringLength);
  metaDescription_ = br.read_string("metaDescription", kMaximumStringLength);
  if (!is_valid_utf8(uniqueID_) ||
      !is_valid_utf8(datasetDescription_) ||
      !is_valid_utf8(metaDescription_)) {
    throw BorgVRException(BorgVRDataErrorCode::InvalidArgument,
                          "Metadata contains invalid UTF-8 text.");
  }
  if (!is_valid_uuid(uniqueID_)) {
    throw BorgVRException(BorgVRDataErrorCode::InvalidArgument, "Invalid dataset UUID.");
  }
  provenance_.clear(); meta_.clear();
  {
    const auto block = read_text_block(br);
    BinaryReader origin(block.data(), block.size());
    const auto count = origin.read_i64("provenance count");
    if (count < 0 || count > 65536 || uint64_t(count) > origin.remaining() / 16)
      throw std::runtime_error("Invalid provenance count.");
    for (int64_t i = 0; i < count; ++i) {
      const auto time = origin.read_i64("provenance timestamp");
      auto text = origin.read_string("provenance entry", kMaximumTextLength);
      if (!is_valid_utf8(text)) throw std::runtime_error("Invalid provenance UTF-8.");
      provenance_.push_back({time, std::move(text)});
    }
    if (origin.remaining()) throw std::runtime_error("Trailing provenance bytes.");
    const auto metaBlock = read_text_block(br);
    meta_.assign(metaBlock.begin(), metaBlock.end());
    if (!is_valid_utf8(meta_)) throw std::runtime_error("Invalid meta UTF-8.");
  }

  const int64_t metadataCount64 = br.read_i64("brickMetadataCount");
  const int64_t dataOffset64 = br.read_i64("brickDataOffset");
  if (metadataCount64 < 0 || dataOffset64 < 0) {
    throw BorgVRException(BorgVRDataErrorCode::InvalidArgument, "Negative brick metadata count/dataOffset.");
  }

  computeLevelMetadata();

  const auto& lastLevel = levelMetadata_.back();
  const int64_t lastLevelBrickCount = static_cast<int64_t>(lastLevel.totalBricks.x) *
                                      static_cast<int64_t>(lastLevel.totalBricks.y) *
                                      static_cast<int64_t>(lastLevel.totalBricks.z);
  const int64_t expectedMetadataCount = static_cast<int64_t>(lastLevel.prevBricks) +
                                        lastLevelBrickCount;
  if (metadataCount64 != expectedMetadataCount) {
    throw BorgVRException(BorgVRDataErrorCode::InvalidArgument,
                          "Brick metadata count does not match the volume hierarchy.");
  }

  if (dataOffset64 > 0) {
    if (static_cast<uint64_t>(dataOffset64) > std::numeric_limits<size_t>::max()) {
      throw BorgVRException(BorgVRDataErrorCode::InvalidArgument,
                            "Brick metadata offset is not representable.");
    }
    br.skip(static_cast<size_t>(dataOffset64), "brickDataOffset");
  }

  const size_t metadataCount = static_cast<size_t>(metadataCount64);
  const size_t brickMetadataRecordSize = 16 +
      static_cast<size_t>(2 * (rangeCount + (scalar ? 1 : 0))) * bytesPerComponent_;
  if (metadataCount > br.remaining() / brickMetadataRecordSize) {
    throw BorgVRException(BorgVRDataErrorCode::InvalidArgument,
                          "Brick metadata records are truncated.");
  }
  brickMetadata_.clear();
  brickMetadata_.reserve(metadataCount);

  for (size_t i = 0; i < metadataCount; ++i) {
    BrickMetadata bm;
    bm.offset = br.read_i64("brick offset");
    bm.size = br.read_i64("brick size");
    ComponentRange brickRange{0, 0};
    if (scalar) brickRange = read_range(br, componentType_, bytesPerComponent_);
    bm.minValue = brickRange.minValue;
    bm.maxValue = brickRange.maxValue;
    bm.componentRanges.reserve(static_cast<size_t>(rangeCount));
    for (int component = 0; component < rangeCount; ++component) {
      bm.componentRanges.push_back(read_range(br, componentType_, bytesPerComponent_));
    }
    if (!scalar && !bm.componentRanges.empty()) brickRange = bm.componentRanges.front();
    bm.minValue = brickRange.minValue;
    bm.maxValue = brickRange.maxValue;
    if (bm.offset < 8 || bm.size <= 0 ||
        bm.offset > std::numeric_limits<int64_t>::max() - bm.size) {
      throw BorgVRException(BorgVRDataErrorCode::InvalidArgument, "Invalid brick byte range.");
    }
    if (bm.size > fullBrickByteCount || (!compression_ && bm.size != fullBrickByteCount)) {
      throw BorgVRException(BorgVRDataErrorCode::InvalidArgument,
                            "Stored brick size does not fit the declared brick layout.");
    }
    if (rangeCount > 0) validate_union(brickRange, bm.componentRanges);
    brickMetadata_.push_back(bm);
  }
}

std::vector<uint8_t> BORGVRMetaData::toBytes() const {
  validate_channel_interpretation(channelInterpretation_, componentType_, bytesPerComponent_, componentCount_);
  std::vector<uint8_t> out;
  out.reserve(1024 + brickMetadata_.size() * 32);

  append_bytes(out, reinterpret_cast<const uint8_t*>(kMagic), kMagicLen);

  append_i64_le(out, static_cast<int64_t>(kVersion));
  append_i64_le(out, static_cast<int64_t>(width_));
  append_i64_le(out, static_cast<int64_t>(height_));
  append_i64_le(out, static_cast<int64_t>(depth_));

  append_i64_le(out, static_cast<int64_t>(componentCount_));
  append_i64_le(out, static_cast<int64_t>(bytesPerComponent_));
  out.push_back(static_cast<uint8_t>(componentType_));
  out.push_back(static_cast<uint8_t>(channelInterpretation_));

  append_f32_le(out, voxelSpacingX_);
  append_f32_le(out, voxelSpacingY_);
  append_f32_le(out, voxelSpacingZ_);

  append_i64_le(out, static_cast<int64_t>(brickSize_));
  append_i64_le(out, static_cast<int64_t>(overlap_));
  if (channelInterpretation_ == ChannelInterpretation::IndependentChannels) {
    append_range(out, {minValue_, maxValue_}, componentType_, bytesPerComponent_);
    append_i64_le(out, static_cast<int64_t>(componentRanges_.size()));
  }
  for (const auto& range : componentRanges_) {
    append_range(out, range, componentType_, bytesPerComponent_);
  }

  append_bool(out, compression_);

  append_string(out, uniqueID_);
  append_string(out, datasetDescription_);
  append_string(out, metaDescription_);
  std::vector<uint8_t> origins;
  append_i64_le(origins, static_cast<int64_t>(provenance_.size()));
  for (const auto& entry : provenance_) {
    append_i64_le(origins, entry.timestampMilliseconds);
    append_string(origins, entry.text);
  }
  append_text_block(out, origins);
  append_text_block(out, std::vector<uint8_t>(meta_.begin(), meta_.end()));

  append_i64_le(out, static_cast<int64_t>(brickMetadata_.size()));

  // Swift toData() uses a dataOffset placeholder of 0.
  append_i64_le(out, static_cast<int64_t>(0));

  for (const auto& b : brickMetadata_) {
    append_i64_le(out, b.offset);
    append_i64_le(out, b.size);
    if (channelInterpretation_ == ChannelInterpretation::IndependentChannels) {
      append_range(out, {b.minValue, b.maxValue}, componentType_, bytesPerComponent_);
    }
    for (const auto& range : b.componentRanges) {
      append_range(out, range, componentType_, bytesPerComponent_);
    }
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
  if (size.x <= 0 || size.y <= 0 || size.z <= 0) {
    throw BorgVRException(BorgVRDataErrorCode::InvalidArgument,
                          "Volume dimensions must be greater than zero.");
  }
  if (brickSize <= 0 || overlap < 0 || overlap > (brickSize - 1) / 2) {
    throw BorgVRException(BorgVRDataErrorCode::InvalidArgument,
                          "Brick size must be greater than twice the overlap.");
  }
  const int effectiveSize = brickSize - 2 * overlap;
  Vec3<int> out{};
  out.x = (size.x - 1) / effectiveSize + 1;
  out.y = (size.y - 1) / effectiveSize + 1;
  out.z = (size.z - 1) / effectiveSize + 1;
  return out;
}

int BORGVRMetaData::calculateLevelCount(Vec3<int> size, int brickSize, int overlap) {
  const auto brickCount = calculateOutputBrickCount(size, brickSize, overlap);
  int maximumBrickCount = std::max({brickCount.x, brickCount.y, brickCount.z});
  int levelCount = 1;
  while (maximumBrickCount > 1) {
    maximumBrickCount = maximumBrickCount / 2 + maximumBrickCount % 2;
    ++levelCount;
  }
  return levelCount;
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

    levelWidth = std::max(1, levelWidth / 2 + levelWidth % 2);
    levelHeight = std::max(1, levelHeight / 2 + levelHeight % 2);
    levelDepth = std::max(1, levelDepth / 2 + levelDepth % 2);

    const int64_t brickCountX = lm.totalBricks.x;
    const int64_t brickCountY = lm.totalBricks.y;
    const int64_t brickCountZ = lm.totalBricks.z;
    if (brickCountX > std::numeric_limits<int64_t>::max() / brickCountY) {
      throw BorgVRException(BorgVRDataErrorCode::InvalidArgument,
                            "Brick hierarchy exceeds the supported integer range.");
    }
    const int64_t brickCountXY = brickCountX * brickCountY;
    if (brickCountXY > std::numeric_limits<int64_t>::max() / brickCountZ) {
      throw BorgVRException(BorgVRDataErrorCode::InvalidArgument,
                            "Brick hierarchy exceeds the supported integer range.");
    }
    const int64_t levelBrickCount = brickCountXY * brickCountZ;
    const int64_t nextBrickCount = static_cast<int64_t>(prevBricks) + levelBrickCount;
    if (nextBrickCount > std::numeric_limits<int>::max()) {
      throw BorgVRException(BorgVRDataErrorCode::InvalidArgument,
                            "Brick hierarchy exceeds the supported integer range.");
    }
    prevBricks = static_cast<int>(nextBrickCount);
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
