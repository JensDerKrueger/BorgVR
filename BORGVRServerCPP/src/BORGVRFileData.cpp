#include "BORGVRFileData.h"
#include "BORGVRDataBase.h"
#include "LZ4.h"

#include <cstring>

BORGVRFileData::BORGVRFileData(const std::string& filename)
  : metadata_(filename),
    mmf_(filename) {

  const size_t bs = static_cast<size_t>(metadata_.brickSize());
  const size_t cc = static_cast<size_t>(metadata_.componentCount());
  const size_t bpc = static_cast<size_t>(metadata_.bytesPerComponent());

  fullBrickSize_ = bs * bs * bs * cc * bpc;
  if (fullBrickSize_ == 0) {
    throw BorgVRException(BorgVRDataErrorCode::InvalidArgument, "Computed fullBrickSize is 0.");
  }
}

void BORGVRFileData::getRawBrick(const BrickMetadata& brickMeta,
                                uint8_t* outputBuffer,
                                size_t outputCapacity) const {
  if (!outputBuffer) {
    throw BorgVRException(BorgVRDataErrorCode::InvalidArgument, "outputBuffer is null.");
  }
  if (brickMeta.size < 0 || brickMeta.offset < 0) {
    throw BorgVRException(BorgVRDataErrorCode::InvalidArgument, "Negative brick offset/size.");
  }
  const size_t size = static_cast<size_t>(brickMeta.size);
  const size_t off = static_cast<size_t>(brickMeta.offset);

  if (size > outputCapacity) {
    throw BorgVRException(BorgVRDataErrorCode::InvalidArgument, "outputBuffer too small for raw brick.");
  }
  if (off + size > mmf_.size()) {
    throw BorgVRException(BorgVRDataErrorCode::IoError, "Brick range out of bounds of mapped file.");
  }

  std::memcpy(outputBuffer, mmf_.data() + off, size);
}

void BORGVRFileData::getBrick(int index,
                             uint8_t* outputBuffer,
                             size_t outputCapacity) const {
  const auto& brickMeta = metadata_.getBrickMetadata(index);

  if (!outputBuffer) {
    throw BorgVRException(BorgVRDataErrorCode::InvalidArgument, "outputBuffer is null.");
  }

  if (outputCapacity < fullBrickSize_) {
    throw BorgVRException(BorgVRDataErrorCode::InvalidArgument, "outputBuffer too small for full brick.");
  }

  if (brickMeta.size < 0 || brickMeta.offset < 0) {
    throw BorgVRException(BorgVRDataErrorCode::InvalidArgument, "Negative brick offset/size.");
  }

  const size_t storedSize = static_cast<size_t>(brickMeta.size);
  const size_t off = static_cast<size_t>(brickMeta.offset);

  if (off + storedSize > mmf_.size()) {
    throw BorgVRException(BorgVRDataErrorCode::IoError, "Brick range out of bounds of mapped file.");
  }

  const uint8_t* src = mmf_.data() + off;

  if (metadata_.compression() && storedSize < fullBrickSize_) {
    const size_t outSize = lz4::decompressBlock(src, storedSize, outputBuffer, fullBrickSize_);
    if (outSize == 0) {
      throw BorgVRException(BorgVRDataErrorCode::DecompressionFailed, "LZ4 decompression failed.");
    }
    if (outSize != fullBrickSize_) {
      throw BorgVRException(BorgVRDataErrorCode::DecompressedSizeMismatch,
                            "Decompressed size mismatch (expected " + std::to_string(fullBrickSize_) +
                            ", got " + std::to_string(outSize) + ")");
    }
  } else {
    // Uncompressed (or already full-sized) brick: copy stored bytes.
    if (storedSize > outputCapacity) {
      throw BorgVRException(BorgVRDataErrorCode::InvalidArgument, "outputBuffer too small for stored brick.");
    }
    std::memcpy(outputBuffer, src, storedSize);
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
