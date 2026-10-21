#include "BORGVRMetaData.h"

#include <cstdint>
#include <functional>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
void write_i64(std::vector<uint8_t>& data, size_t offset, int64_t value) {
  const uint64_t raw = static_cast<uint64_t>(value);
  for (size_t index = 0; index < 8; ++index) {
    data.at(offset + index) = static_cast<uint8_t>((raw >> (index * 8)) & 0xff);
  }
}

int64_t read_i64(const std::vector<uint8_t>& data, size_t offset) {
  uint64_t raw = 0;
  for (size_t index = 0; index < 8; ++index) {
    raw |= static_cast<uint64_t>(data.at(offset + index)) << (index * 8);
  }
  return static_cast<int64_t>(raw);
}

size_t brick_count_offset(const std::vector<uint8_t>& data) {
  const auto componentCount = static_cast<size_t>(read_i64(data, 38));
  size_t offset = 107 + componentCount * 16;
  for (int index = 0; index < 3; ++index) {
    const auto length = static_cast<size_t>(read_i64(data, offset));
    offset += 8 + length;
  }
  return offset;
}

void expect_rejection(const std::string& name,
                      const std::vector<uint8_t>& data) {
  try {
    BORGVRMetaData metadata;
    metadata.parseFromBytes(data.data(), data.size());
  } catch (const std::exception&) {
    return;
  }
  throw std::runtime_error("Expected parser rejection: " + name);
}
}  // namespace

int main(int argc, char** argv) {
  if (argc != 2) {
    std::cerr << "Usage: metadata_parser_tests <valid-data-file>\n";
    return 2;
  }

  std::ifstream input(argv[1], std::ios::binary);
  if (!input) throw std::runtime_error("Unable to open metadata test fixture.");
  const std::vector<uint8_t> valid(
      (std::istreambuf_iterator<char>(input)),
      std::istreambuf_iterator<char>());
  BORGVRMetaData parsed;
  parsed.parseFromBytes(valid.data(), valid.size());
  if (parsed.componentRanges().size() != static_cast<size_t>(parsed.componentCount())) {
    throw std::runtime_error("Component ranges did not survive metadata round trip.");
  }

  auto truncated = valid;
  truncated.pop_back();
  expect_rejection("truncated metadata", truncated);

  auto negativeWidth = valid;
  write_i64(negativeWidth, 14, -1);
  expect_rejection("negative width", negativeWidth);

  auto oversizedWidth = valid;
  write_i64(oversizedWidth, 14, INT64_MAX);
  expect_rejection("oversized width", oversizedWidth);

  auto invalidComponentSize = valid;
  write_i64(invalidComponentSize, 46, 3);
  expect_rejection("unsupported component size", invalidComponentSize);

  auto invalidSpacing = valid;
  invalidSpacing[54] = 0x00;
  invalidSpacing[55] = 0x00;
  invalidSpacing[56] = 0xc0;
  invalidSpacing[57] = 0x7f;
  expect_rejection("non-finite voxel spacing", invalidSpacing);

  auto invalidOverlap = valid;
  write_i64(invalidOverlap, 74, parsed.brickSize() / 2 + 1);
  expect_rejection("invalid brick stride", invalidOverlap);

  auto invalidBoolean = valid;
  const size_t componentCount = static_cast<size_t>(read_i64(valid, 38));
  const size_t compressionOffset = 106 + componentCount * 16;
  invalidBoolean[compressionOffset] = 2;
  expect_rejection("invalid Boolean", invalidBoolean);

  auto negativeStringLength = valid;
  const size_t firstStringOffset = compressionOffset + 1;
  write_i64(negativeStringLength, firstStringOffset, -1);
  expect_rejection("negative string length", negativeStringLength);

  auto oversizedStringLength = valid;
  write_i64(oversizedStringLength, firstStringOffset, 1'048'577);
  expect_rejection("oversized string length", oversizedStringLength);

  const size_t uniqueIDLength = static_cast<size_t>(read_i64(valid, firstStringOffset));
  const size_t datasetDescriptionStart = firstStringOffset + 8 + uniqueIDLength + 8;
  auto invalidUTF8 = valid;
  invalidUTF8.at(datasetDescriptionStart) = 0xff;
  expect_rejection("invalid UTF-8", invalidUTF8);

  const size_t metadataCountOffset = brick_count_offset(valid);
  auto negativeBrickCount = valid;
  write_i64(negativeBrickCount, metadataCountOffset, -1);
  expect_rejection("negative brick count", negativeBrickCount);

  auto inconsistentBrickCount = valid;
  write_i64(inconsistentBrickCount, metadataCountOffset, 1);
  expect_rejection("inconsistent brick count", inconsistentBrickCount);

  auto oversizedDataOffset = valid;
  write_i64(oversizedDataOffset, metadataCountOffset + 8, INT64_MAX);
  expect_rejection("oversized brick metadata offset", oversizedDataOffset);

  auto overflowingBrickRange = valid;
  write_i64(overflowingBrickRange, metadataCountOffset + 16, INT64_MAX);
  expect_rejection("overflowing brick range", overflowingBrickRange);

  std::cout << "C++ BORGVR metadata parser tests passed.\n";
  return 0;
}
