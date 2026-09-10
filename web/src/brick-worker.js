import { decodeAppleLZ4 } from "./lz4.js?v=20260911-worker";

const BATCH_MAGIC = 0x31425642;

let config = null;

self.addEventListener("message", (event) => {
  const message = event.data;
  if (message?.type === "configure") {
    config = message.config;
    return;
  }
  if (message?.type === "loadBatch") {
    loadBatch(message).catch((error) => {
      self.postMessage({
        type: "batchFailed",
        requestID: message.requestID,
        generation: message.generation,
        error: error.message ?? String(error),
        httpStatus: error.httpStatus ?? 0
      });
    });
  }
});

async function loadBatch(message) {
  if (!config) {
    throw new Error("Brick worker is not configured.");
  }

  const profile = createProfile();
  const decodedBricks = message.brickIDs.length === 1
    ? await fetchSingleBrick(message.brickIDs[0], profile)
    : await fetchBatchBricks(message.brickIDs, profile);
  const preparedBricks = [];
  const transferList = [];

  for (const brickID of message.brickIDs) {
    const brickData = decodedBricks.get(brickID);
    if (!brickData) {
      continue;
    }
    const prepareStart = now();
    const prepared = prepareBrickUploadData(brickData);
    profile.uploadPrepareMs += now() - prepareStart;
    profile.uploadedBytes += prepared.data.byteLength;
    preparedBricks.push({
      brickID,
      data: prepared.data,
      bytesPerRow: prepared.bytesPerRow,
      rowsPerImage: prepared.rowsPerImage
    });
    transferList.push(prepared.data.buffer);
  }

  self.postMessage({
    type: "batchLoaded",
    requestID: message.requestID,
    generation: message.generation,
    bricks: preparedBricks,
    profile
  }, transferList);
}

async function fetchBatchBricks(brickIDs, profile) {
  const url = new URL("bricks.batch", config.baseURL);
  url.searchParams.set("ids", brickIDs.join(","));
  const fetchStart = now();
  const response = await fetch(url, { credentials: "same-origin" });
  profile.fetchHeaderMs += now() - fetchStart;

  if (!response.ok) {
    if (response.status === 404) {
      const entries = await Promise.all(brickIDs.map((brickID) => fetchSingleBrick(brickID, profile)));
      const bricksByID = new Map();
      for (const entry of entries) {
        for (const [brickID, brickData] of entry) {
          bricksByID.set(brickID, brickData);
        }
      }
      return bricksByID;
    }
    const error = new Error(`HTTP ${response.status} while loading brick batch`);
    error.httpStatus = response.status;
    throw error;
  }

  const bodyStart = now();
  const batchData = new Uint8Array(await response.arrayBuffer());
  profile.fetchBodyMs += now() - bodyStart;
  profile.batchRequests += 1;

  const view = new DataView(batchData.buffer, batchData.byteOffset, batchData.byteLength);
  if (batchData.byteLength < 8 || view.getUint32(0, true) !== BATCH_MAGIC) {
    throw new Error("Invalid BorgVR brick batch header.");
  }

  const count = view.getUint32(4, true);
  const tableByteLength = 8 + count * 12;
  if (batchData.byteLength < tableByteLength) {
    throw new Error("Truncated BorgVR brick batch table.");
  }

  const bricksByID = new Map();
  for (let index = 0; index < count; index += 1) {
    const entryOffset = 8 + index * 12;
    const brickID = view.getUint32(entryOffset, true);
    const dataOffset = view.getUint32(entryOffset + 4, true);
    const byteLength = view.getUint32(entryOffset + 8, true);
    if (dataOffset < tableByteLength || dataOffset + byteLength > batchData.byteLength) {
      throw new Error("Invalid BorgVR brick batch entry.");
    }

    const brick = config.bricks[brickID];
    if (!brick) {
      continue;
    }
    const storedData = batchData.subarray(dataOffset, dataOffset + byteLength);
    bricksByID.set(brickID, decodeStoredBrick(brick, storedData, profile));
  }
  return bricksByID;
}

async function fetchSingleBrick(brickID, profile) {
  const brick = config.bricks[brickID];
  if (!brick) {
    return new Map();
  }

  const brickName = String(brick.index).padStart(6, "0");
  const url = new URL(brick.url ?? `bricks/${brickName}`, config.baseURL);
  const fetchStart = now();
  let response = await fetch(url, { credentials: "same-origin" });
  let requestedURL = url;
  if (!response.ok && response.status === 404 && !brick.url) {
    const extension = effectiveBrickCompression(brick) === "lz4" ? "lz4" : "bin";
    requestedURL = new URL(`bricks/${brickName}.${extension}`, config.baseURL);
    response = await fetch(requestedURL, { credentials: "same-origin" });
  }
  profile.fetchHeaderMs += now() - fetchStart;
  if (!response.ok) {
    throw new Error(`HTTP ${response.status} while loading ${requestedURL.pathname}`);
  }

  const bodyStart = now();
  const data = new Uint8Array(await response.arrayBuffer());
  profile.fetchBodyMs += now() - bodyStart;

  return new Map([[brickID, decodeStoredBrick(brick, data, profile)]]);
}

function decodeStoredBrick(brick, data, profile) {
  profile.compressedBytes += data.byteLength;
  const uncompressedByteLength = uncompressedByteLengthFor(brick);
  if (shouldDecompressBrick(brick, data)) {
    const decodeStart = now();
    const decoded = decodeAppleLZ4(data, uncompressedByteLength);
    profile.lz4DecodeMs += now() - decodeStart;
    profile.decodedBytes += decoded.byteLength;
    profile.lz4Bricks += 1;
    return decoded;
  }

  if (data.byteLength !== uncompressedByteLength) {
    throw new Error(`raw brick ${brick.index} has ${data.byteLength} bytes, expected ${uncompressedByteLength}`);
  }
  profile.decodedBytes += data.byteLength;
  profile.rawBricks += 1;
  return data;
}

function shouldDecompressBrick(brick, data) {
  return effectiveBrickCompression(brick) === "lz4" &&
    data.byteLength < uncompressedByteLengthFor(brick);
}

function uncompressedByteLengthFor(brick) {
  return brick.uncompressedByteLength ?? config.uncompressedBrickByteLength;
}

function effectiveBrickCompression(brick) {
  const brickCompression = normalizeCompressionName(brick.compression);
  if (brickCompression && brickCompression !== "per-brick") {
    return brickCompression;
  }
  return config.datasetCompression === "per-brick" ? "lz4" : config.datasetCompression;
}

function prepareBrickUploadData(brickData) {
  const bytesPerRow = align(config.brickSize * config.textureBytesPerVoxel, 256);
  const rowsPerImage = config.brickSize;
  const paddedData = new Uint8Array(bytesPerRow * rowsPerImage * config.brickSize);
  const sourceBytesPerRow = config.brickSize * config.bytesPerVoxel;

  for (let z = 0; z < config.brickSize; z += 1) {
    for (let y = 0; y < config.brickSize; y += 1) {
      const sourceOffset = (z * config.brickSize + y) * sourceBytesPerRow;
      const destinationOffset = (z * rowsPerImage + y) * bytesPerRow;
      if (config.bytesPerComponent === 1) {
        paddedData.set(brickData.subarray(sourceOffset, sourceOffset + sourceBytesPerRow), destinationOffset);
      } else {
        for (let x = 0; x < config.brickSize; x += 1) {
          const sourceVoxelOffset = sourceOffset + x * config.bytesPerVoxel;
          const value = brickData[sourceVoxelOffset] | (brickData[sourceVoxelOffset + 1] << 8);
          const normalizedValue = Math.min(1, Math.max(0, value / Math.max(1, config.dataRangeMax)));
          writeUInt16LE(paddedData, destinationOffset + x * config.textureBytesPerVoxel, float32ToFloat16Bits(normalizedValue));
        }
      }
    }
  }

  return { data: paddedData, bytesPerRow, rowsPerImage };
}

function createProfile() {
  return {
    loadedBricks: 0,
    failedBricks: 0,
    batchRequests: 0,
    lz4Bricks: 0,
    rawBricks: 0,
    compressedBytes: 0,
    decodedBytes: 0,
    uploadedBytes: 0,
    fetchHeaderMs: 0,
    fetchBodyMs: 0,
    lz4DecodeMs: 0,
    uploadPrepareMs: 0,
    uploadSubmitMs: 0,
    totalLoadMs: 0
  };
}

function normalizeCompressionName(value) {
  if (value === "lz4" || value === "none" || value === "per-brick") {
    return value;
  }
  return null;
}

function writeUInt16LE(data, offset, value) {
  data[offset] = value & 0xff;
  data[offset + 1] = (value >> 8) & 0xff;
}

function float32ToFloat16Bits(value) {
  const floatView = new Float32Array(1);
  const intView = new Uint32Array(floatView.buffer);
  floatView[0] = value;

  const bits = intView[0];
  const sign = (bits >>> 16) & 0x8000;
  let exponent = ((bits >>> 23) & 0xff) - 127 + 15;
  let mantissa = bits & 0x7fffff;

  if (exponent <= 0) {
    if (exponent < -10) {
      return sign;
    }
    mantissa = (mantissa | 0x800000) >>> (1 - exponent);
    return sign | ((mantissa + 0x1000) >>> 13);
  }

  if (exponent >= 31) {
    return sign | 0x7c00;
  }

  return sign | (exponent << 10) | ((mantissa + 0x1000) >>> 13);
}

function align(value, alignment) {
  return Math.ceil(value / alignment) * alignment;
}

function now() {
  return performance.now();
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
