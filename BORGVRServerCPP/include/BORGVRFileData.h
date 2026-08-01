#pragma once

#include "BORGVRMetaData.h"
#include "MemoryMappedFile.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

class BORGVRFileData {
public:
  explicit BORGVRFileData(const std::string& filename);

  const BORGVRMetaData& metadata() const { return metadata_; }
  size_t fullBrickSize() const { return fullBrickSize_; }

  // Allocate a reusable buffer big enough for a full (decompressed) brick.
  std::vector<uint8_t> allocateBrickBuffer() const { return std::vector<uint8_t>(fullBrickSize_); }

  // Decompresses if required and writes a full brick (fullBrickSize()) to outputBuffer.
  void getBrick(int index, uint8_t* outputBuffer, size_t outputCapacity) const;

  // Copies the stored brick bytes (compressed or uncompressed) into outputBuffer.
  void getRawBrick(const BrickMetadata& brickMeta, uint8_t* outputBuffer, size_t outputCapacity) const;

private:
  BORGVRMetaData metadata_;
  MemoryMappedFile mmf_;
  size_t fullBrickSize_ = 0;
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
