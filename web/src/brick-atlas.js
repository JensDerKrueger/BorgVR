export const BI_MISSING = 0;
const BI_CHILD_EMPTY = 1;
const BI_EMPTY = 2;
const BI_FLAG_COUNT = 3;

const MAX_CONCURRENT_BRICK_LOADS = 128;
const MAX_BRICKS_PER_BATCH_REQUEST = 32;
const MAX_PENDING_REQUEST_AGE_FRAMES = 10;
const DEFAULT_ATLAS_MEMORY_BYTES = 2 * 1024 * 1024 * 1024;
const BATCH_MAGIC = 0x31425642;

export class BrickAtlas {
  constructor(device, statusCallback = null, activityCallback = null) {
    this.device = device;
    this.statusCallback = statusCallback;
    this.activityCallback = activityCallback;
    this.generation = 0;
    this.profilingEnabled = false;
    this.profile = createAtlasProfile();
    this.resetState();
  }

  setProfiling(enabled) {
    this.profilingEnabled = enabled;
    this.profile = createAtlasProfile();
  }

  profileSnapshot() {
    const profile = this.profile;
    const loadedCount = Math.max(1, profile.loadedBricks);
    return {
      loads: profile.loadedBricks,
      failed: profile.failedBricks,
      batchRequests: profile.batchRequests,
      compressedMiB: bytesToMiB(profile.compressedBytes),
      decodedMiB: bytesToMiB(profile.decodedBytes),
      uploadedMiB: bytesToMiB(profile.uploadedBytes),
      fetchHeaderMs: profile.fetchHeaderMs,
      fetchBodyMs: profile.fetchBodyMs,
      lz4DecodeMs: profile.lz4DecodeMs,
      uploadPrepareMs: profile.uploadPrepareMs,
      uploadSubmitMs: profile.uploadSubmitMs,
      totalLoadMs: profile.totalLoadMs,
      avgFetchHeaderMs: profile.fetchHeaderMs / loadedCount,
      avgFetchBodyMs: profile.fetchBodyMs / loadedCount,
      avgFetchHeaderMsPerBatch: profile.fetchHeaderMs / Math.max(1, profile.batchRequests),
      avgFetchBodyMsPerBatch: profile.fetchBodyMs / Math.max(1, profile.batchRequests),
      avgLZ4DecodeMs: profile.lz4DecodeMs / Math.max(1, profile.lz4Bricks),
      avgUploadPrepareMs: profile.uploadPrepareMs / loadedCount,
      avgUploadSubmitMs: profile.uploadSubmitMs / loadedCount,
      avgTotalLoadMs: profile.totalLoadMs / loadedCount,
      lz4Bricks: profile.lz4Bricks,
      rawBricks: profile.rawBricks
    };
  }

  reset(manifest, transferFunction = null, options = {}) {
    this.generation += 1;
    this.destroy();
    this.resetState();
    this.manifest = manifest;
    this.baseURL = manifest.baseURL;
    this.brickSize = manifest.bricking.brickSize;
    this.componentCount = manifest.volume.componentCount;
    this.bytesPerComponent = manifest.volume.bytesPerComponent;
    this.bytesPerVoxel = this.componentCount * this.bytesPerComponent;
    this.uncompressedBrickByteLength = this.brickSize * this.brickSize * this.brickSize * this.bytesPerVoxel;
    this.datasetCompression = normalizeCompressionName(manifest.bricking?.compression) ?? "none";
    this.dataRangeMax = manifest.volume?.dataRange?.[1] ?? ((2 ** (8 * this.bytesPerComponent)) - 1);
    this.textureFormat = this.bytesPerComponent === 1 ? "r8unorm" : "r16float";
    this.textureBytesPerVoxel = this.bytesPerComponent === 1 ? 1 : 2;
    this.totalBrickCount = manifest.bricks.length;
    this.brickMeta = new Uint32Array(this.totalBrickCount);
    this.brickMeta.fill(BI_MISSING);
    this.brickClassification = classifyBricks(manifest, transferFunction, options);
    this.brickMeta.set(this.brickClassification.meta);

    const maxTextureBricks = Math.max(1, Math.floor(this.device.limits.maxTextureDimension3D / this.brickSize));
    const brickTextureBytes = this.brickSize * this.brickSize * this.brickSize * this.textureBytesPerVoxel;
    const maxMemoryBricks = Math.max(1, Math.floor(Math.cbrt(DEFAULT_ATLAS_MEMORY_BYTES / Math.max(1, brickTextureBytes))));
    const maxAtlasBricksPerAxis = Math.min(maxTextureBricks, maxMemoryBricks);
    const targetSlots = Math.min(Math.max(1, this.totalBrickCount), maxAtlasBricksPerAxis ** 3);
    this.atlasBricksPerAxis = Math.max(1, Math.min(maxAtlasBricksPerAxis, Math.ceil(Math.cbrt(targetSlots))));
    this.slotCapacity = targetSlots;
    this.textureSize = this.atlasBricksPerAxis * this.brickSize;

    if (this.componentCount !== 1 || (this.bytesPerComponent !== 1 && this.bytesPerComponent !== 2)) {
      this.statusCallback?.(`Atlas ready, but ${this.componentCount} x ${8 * this.bytesPerComponent}-bit bricks need a later texture-format path.`);
      return;
    }

    this.texture = this.device.createTexture({
      size: [this.textureSize, this.textureSize, this.textureSize],
      dimension: "3d",
      format: this.textureFormat,
      usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST
    });
    const maxStorageBufferBindingSize = this.device.limits.maxStorageBufferBindingSize ?? this.device.limits.maxBufferSize;
    if (this.brickMeta.byteLength > maxStorageBufferBindingSize) {
      throw new Error(`Brick metadata buffer needs ${formatMiB(this.brickMeta.byteLength)}, but WebGPU only allows ${formatMiB(maxStorageBufferBindingSize)} storage-buffer bindings.`);
    }
    this.brickMetaBuffer = this.device.createBuffer({
      size: this.brickMeta.byteLength,
      usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST
    });
    this.device.queue.writeBuffer(this.brickMetaBuffer, 0, this.brickMeta);

    this.freeSlots = Array.from({ length: this.slotCapacity }, (_, index) => index);
    this.statusCallback?.(
      `Atlas ready: ${this.textureSize}³ ${this.textureFormat} voxels, ${this.slotCapacity} slots for ${this.totalBrickCount} bricks`
    );
    this.prefetchCoarsestLevel();
  }

  reclassify(transferFunction = null, options = {}) {
    if (!this.manifest || !this.brickMetaBuffer || this.brickMeta.length === 0) {
      return;
    }

    this.brickClassification = classifyBricks(this.manifest, transferFunction, options);
    const nextMeta = new Uint32Array(this.brickClassification.meta);
    for (const [brickID, slot] of this.loadedBricks) {
      if (nextMeta[brickID] === BI_MISSING) {
        nextMeta[brickID] = slot + BI_FLAG_COUNT;
        continue;
      }
      if (this.protectedBrickIDs.has(brickID)) {
        continue;
      }
      this.loadedBricks.delete(brickID);
      this.freeSlots.unshift(slot);
    }
    this.residentOrder = this.residentOrder.filter((brickID) => this.loadedBricks.has(brickID));

    this.brickMeta = nextMeta;
    this.device.queue.writeBuffer(this.brickMetaBuffer, 0, this.brickMeta);

    this.pendingBrickIDs = this.pendingBrickIDs.filter((brickID) => {
      if (brickID < 0 || brickID >= this.totalBrickCount) {
        this.pendingRequestFrames.delete(brickID);
        this.loadingBricks.delete(brickID);
        return false;
      }
      const isStillVisible = this.brickMeta[brickID] !== BI_EMPTY &&
        this.brickMeta[brickID] !== BI_CHILD_EMPTY &&
        !this.loadedBricks.has(brickID);
      if (!isStillVisible) {
        this.pendingRequestFrames.delete(brickID);
        this.loadingBricks.delete(brickID);
      }
      return isStillVisible;
    });
    this.pumpLoads();
  }

  destroy() {
    this.texture?.destroy();
    this.brickMetaBuffer?.destroy();
  }

  beginFrame(frameIndex) {
    this.currentFrame = frameIndex;
    this.pruneStalePendingRequests();
  }

  requestBricks(brickIDs, options = {}) {
    if (!this.texture || !this.brickMetaBuffer || !this.baseURL) {
      return;
    }

    const protect = options.protect === true;
    const queueFront = options.queueFront !== false;
    const enqueuedBrickIDs = [];

    for (const brickID of brickIDs) {
      if (protect && brickID >= 0 && brickID < this.totalBrickCount) {
        this.protectedBrickIDs.add(brickID);
      }
      if (this.pendingRequestFrames.has(brickID)) {
        this.pendingRequestFrames.set(brickID, this.currentFrame);
        continue;
      }
      if (this.shouldLoadBrick(brickID)) {
        this.loadingBricks.add(brickID);
        this.pendingRequestFrames.set(brickID, this.currentFrame);
        enqueuedBrickIDs.push(brickID);
      }
    }

    if (enqueuedBrickIDs.length > 0) {
      if (queueFront) {
        this.pendingBrickIDs = enqueuedBrickIDs.concat(this.pendingBrickIDs);
      } else {
        this.pendingBrickIDs.push(...enqueuedBrickIDs);
      }
      this.pumpLoads();
    }
  }

  prefetchCoarsestLevel() {
    const levels = [...(this.manifest.levels ?? [])].sort((a, b) => a.level - b.level);
    const coarsestLevel = levels[levels.length - 1];
    if (!coarsestLevel) {
      return;
    }

    const count = coarsestLevel.brickCount[0] * coarsestLevel.brickCount[1] * coarsestLevel.brickCount[2];
    const brickIDs = [];
    for (let offset = 0; offset < count; offset += 1) {
      brickIDs.push(coarsestLevel.firstBrick + offset);
    }
    this.requestBricks(brickIDs, { protect: true, queueFront: false });
  }

  summary() {
    const emptyTotal = this.brickClassification.emptyCount + this.brickClassification.childEmptyCount;
    const emptyText = emptyTotal > 0
      ? `, empty ${emptyTotal} (${this.brickClassification.emptyCount} plain, ${this.brickClassification.childEmptyCount} child)`
      : "";
    return `atlas ${this.loadedBricks.size}/${this.slotCapacity}, active ${this.activeLoads}, queued ${this.pendingBrickIDs.length}, evicted ${this.evictedBricks}, stale ${this.droppedStaleRequests}${emptyText}`;
  }

  resetState() {
    this.manifest = null;
    this.baseURL = "";
    this.brickSize = 0;
    this.componentCount = 0;
    this.bytesPerComponent = 0;
    this.bytesPerVoxel = 0;
    this.uncompressedBrickByteLength = 0;
    this.dataRangeMax = 1;
    this.textureFormat = "r8unorm";
    this.textureBytesPerVoxel = 1;
    this.totalBrickCount = 0;
    this.atlasBricksPerAxis = 0;
    this.slotCapacity = 0;
    this.textureSize = 0;
    this.texture = null;
    this.brickMetaBuffer = null;
    this.brickMeta = new Uint32Array(0);
    this.freeSlots = [];
    this.loadedBricks = new Map();
    this.loadingBricks = new Set();
    this.protectedBrickIDs = new Set();
    this.residentOrder = [];
    this.pendingBrickIDs = [];
    this.pendingRequestFrames = new Map();
    this.activeLoads = 0;
    this.failedLoads = 0;
    this.evictedBricks = 0;
    this.currentFrame = 0;
    this.droppedStaleRequests = 0;
    this.brickClassification = {
      meta: new Uint32Array(0),
      emptyCount: 0,
      childEmptyCount: 0,
      fullyOpaqueCount: 0
    };
  }

  shouldLoadBrick(brickID) {
    if (brickID < 0 || brickID >= this.totalBrickCount) {
      return false;
    }
    if (this.loadedBricks.has(brickID) || this.loadingBricks.has(brickID)) {
      return false;
    }
    if (this.brickMeta[brickID] === BI_EMPTY || this.brickMeta[brickID] === BI_CHILD_EMPTY) {
      return false;
    }
    return this.freeSlots.length > 0 || this.hasEvictableSlot();
  }

  pumpLoads() {
    const generation = this.generation;
    this.pruneStalePendingRequests();
    while (this.activeLoads < MAX_CONCURRENT_BRICK_LOADS &&
           this.pendingBrickIDs.length > 0 &&
           (this.freeSlots.length > 0 || this.hasEvictableSlot())) {
      const batchIDs = [];
      const batchLimit = Math.min(
        MAX_BRICKS_PER_BATCH_REQUEST,
        MAX_CONCURRENT_BRICK_LOADS - this.activeLoads
      );
      while (batchIDs.length < batchLimit && this.pendingBrickIDs.length > 0) {
        const brickID = this.pendingBrickIDs.shift();
        this.pendingRequestFrames.delete(brickID);
        batchIDs.push(brickID);
      }

      if (batchIDs.length === 0) {
        break;
      }

      this.activeLoads += batchIDs.length;
      this.loadBrickBatch(batchIDs, generation)
        .catch((error) => {
          if (generation !== this.generation) {
            return;
          }
          this.profile.failedBricks += batchIDs.length;
          this.failedLoads += batchIDs.length;
          this.statusCallback?.(`Atlas brick batch failed: ${error.message ?? String(error)}`);
        })
        .finally(() => {
          if (generation !== this.generation) {
            return;
          }
          this.activeLoads -= batchIDs.length;
          batchIDs.forEach((brickID) => this.loadingBricks.delete(brickID));
          this.pumpLoads();
        });
    }
  }

  pruneStalePendingRequests() {
    if (this.pendingBrickIDs.length === 0) {
      return;
    }

    const retainedBrickIDs = [];
    for (const brickID of this.pendingBrickIDs) {
      const lastRequestedFrame = this.pendingRequestFrames.get(brickID);
      if (this.protectedBrickIDs.has(brickID) ||
          (lastRequestedFrame !== undefined &&
           this.currentFrame - lastRequestedFrame <= MAX_PENDING_REQUEST_AGE_FRAMES)) {
        retainedBrickIDs.push(brickID);
      } else {
        this.loadingBricks.delete(brickID);
        this.pendingRequestFrames.delete(brickID);
        this.droppedStaleRequests += 1;
      }
    }
    this.pendingBrickIDs = retainedBrickIDs;
  }

  async loadBrickBatch(brickIDs, generation = this.generation) {
    if (brickIDs.length === 1) {
      await this.loadBrick(brickIDs[0], generation);
      return;
    }

    const batchStart = now();
    let brickDataByID;
    try {
      brickDataByID = await this.fetchBrickBatchData(brickIDs);
    } catch (error) {
      if (error?.httpStatus !== 404) {
        throw error;
      }
      await Promise.all(brickIDs.map((brickID) => this.loadBrick(brickID, generation)));
      return;
    }

    if (generation !== this.generation) {
      return;
    }

    for (const brickID of brickIDs) {
      const brickData = brickDataByID.get(brickID);
      if (!brickData) {
        continue;
      }
      if (this.brickMeta[brickID] === BI_EMPTY || this.brickMeta[brickID] === BI_CHILD_EMPTY) {
        continue;
      }

      const slot = this.acquireSlot();
      if (slot === undefined) {
        continue;
      }

      try {
        this.uploadBrick(slot, brickData);
      } catch (error) {
        this.freeSlots.unshift(slot);
        throw error;
      }
      if (generation !== this.generation) {
        this.freeSlots.unshift(slot);
        return;
      }

      this.loadedBricks.set(brickID, slot);
      this.residentOrder.push(brickID);
      this.brickMeta[brickID] = slot + BI_FLAG_COUNT;
      this.device.queue.writeBuffer(
        this.brickMetaBuffer,
        brickID * Uint32Array.BYTES_PER_ELEMENT,
        new Uint32Array([this.brickMeta[brickID]])
      );
      this.profile.loadedBricks += 1;
    }

    this.recordProfile("totalLoadMs", now() - batchStart);
    this.activityCallback?.();

    if (this.loadedBricks.size === 1 || this.loadedBricks.size % 16 === 0) {
      this.statusCallback?.(`Atlas loaded ${this.loadedBricks.size}/${this.slotCapacity} slots`);
    }
  }

  async loadBrick(brickID, generation = this.generation) {
    const loadStart = now();
    const brick = this.manifest.bricks[brickID];
    if (!brick) {
      return;
    }

    const slot = this.acquireSlot();
    if (slot === undefined) {
      return;
    }

    let brickData;
    try {
      brickData = await this.fetchBrickData(brick);
      if (generation !== this.generation) {
        return;
      }
      if (this.brickMeta[brickID] === BI_EMPTY || this.brickMeta[brickID] === BI_CHILD_EMPTY) {
        this.freeSlots.unshift(slot);
        return;
      }
      this.uploadBrick(slot, brickData);
    } catch (error) {
      if (generation === this.generation) {
        this.freeSlots.unshift(slot);
      }
      throw error;
    }
    if (generation !== this.generation) {
      return;
    }
    this.recordProfile("totalLoadMs", now() - loadStart);
    this.profile.loadedBricks += 1;
    this.loadedBricks.set(brickID, slot);
    this.residentOrder.push(brickID);
    this.brickMeta[brickID] = slot + BI_FLAG_COUNT;
    this.device.queue.writeBuffer(
      this.brickMetaBuffer,
      brickID * Uint32Array.BYTES_PER_ELEMENT,
      new Uint32Array([this.brickMeta[brickID]])
    );
    this.activityCallback?.();

    if (this.loadedBricks.size === 1 || this.loadedBricks.size % 16 === 0) {
      this.statusCallback?.(`Atlas loaded ${this.loadedBricks.size}/${this.slotCapacity} slots`);
    }
  }

  hasEvictableSlot() {
    for (const brickID of this.residentOrder) {
      if (!this.protectedBrickIDs.has(brickID) && this.loadedBricks.has(brickID)) {
        return true;
      }
    }
    return false;
  }

  acquireSlot() {
    const freeSlot = this.freeSlots.shift();
    if (freeSlot !== undefined) {
      return freeSlot;
    }
    return this.evictOldestBrick();
  }

  evictOldestBrick() {
    while (this.residentOrder.length > 0) {
      const brickID = this.residentOrder.shift();
      if (this.protectedBrickIDs.has(brickID)) {
        continue;
      }

      const slot = this.loadedBricks.get(brickID);
      if (slot === undefined) {
        continue;
      }

      this.loadedBricks.delete(brickID);
      this.brickMeta[brickID] = BI_MISSING;
      this.device.queue.writeBuffer(
        this.brickMetaBuffer,
        brickID * Uint32Array.BYTES_PER_ELEMENT,
        new Uint32Array([BI_MISSING])
      );
      this.evictedBricks += 1;
      return slot;
    }
    return undefined;
  }

  async fetchBrickData(brick) {
    const brickName = String(brick.index).padStart(6, "0");
    const url = new URL(brick.url ?? `bricks/${brickName}`, this.baseURL);
    const fetchStart = now();
    let response = await fetch(url, { credentials: "same-origin" });
    let requestedURL = url;
    if (!response.ok && response.status === 404 && !brick.url) {
      const extension = this.effectiveBrickCompression(brick) === "lz4" ? "lz4" : "bin";
      requestedURL = new URL(`bricks/${brickName}.${extension}`, this.baseURL);
      response = await fetch(requestedURL, { credentials: "same-origin" });
    }
    this.recordProfile("fetchHeaderMs", now() - fetchStart);
    if (!response.ok) {
      throw new Error(`HTTP ${response.status} while loading ${requestedURL.pathname}`);
    }
    const bodyStart = now();
    const data = new Uint8Array(await response.arrayBuffer());
    this.recordProfile("fetchBodyMs", now() - bodyStart);
    this.profile.compressedBytes += data.byteLength;
    const uncompressedByteLength = this.uncompressedByteLengthFor(brick);

    if (this.shouldDecompressBrick(brick, data)) {
      const decodeStart = now();
      const decoded = decodeAppleLZ4(data, uncompressedByteLength);
      this.recordProfile("lz4DecodeMs", now() - decodeStart);
      this.profile.decodedBytes += decoded.byteLength;
      this.profile.lz4Bricks += 1;
      return decoded;
    }
    if (data.byteLength !== uncompressedByteLength) {
      throw new Error(`raw brick has ${data.byteLength} bytes, expected ${uncompressedByteLength}`);
    }
    this.profile.decodedBytes += data.byteLength;
    this.profile.rawBricks += 1;
    return data;
  }

  async fetchBrickBatchData(brickIDs) {
    const url = new URL("bricks.batch", this.baseURL);
    url.searchParams.set("ids", brickIDs.join(","));
    const fetchStart = now();
    const response = await fetch(url, { credentials: "same-origin" });
    this.recordProfile("fetchHeaderMs", now() - fetchStart);
    if (!response.ok) {
      const error = new Error(`HTTP ${response.status} while loading brick batch`);
      error.httpStatus = response.status;
      throw error;
    }

    const bodyStart = now();
    const batchData = new Uint8Array(await response.arrayBuffer());
    this.recordProfile("fetchBodyMs", now() - bodyStart);
    this.profile.batchRequests += 1;

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

      const brick = this.manifest.bricks[brickID];
      if (!brick) {
        continue;
      }
      const storedData = batchData.subarray(dataOffset, dataOffset + byteLength);
      this.profile.compressedBytes += storedData.byteLength;
      const uncompressedByteLength = this.uncompressedByteLengthFor(brick);
      if (this.shouldDecompressBrick(brick, storedData)) {
        const decodeStart = now();
        const decoded = decodeAppleLZ4(storedData, uncompressedByteLength);
        this.recordProfile("lz4DecodeMs", now() - decodeStart);
        this.profile.decodedBytes += decoded.byteLength;
        this.profile.lz4Bricks += 1;
        bricksByID.set(brickID, decoded);
      } else {
        if (storedData.byteLength !== uncompressedByteLength) {
          throw new Error(`raw brick ${brickID} has ${storedData.byteLength} bytes, expected ${uncompressedByteLength}`);
        }
        this.profile.decodedBytes += storedData.byteLength;
        this.profile.rawBricks += 1;
        bricksByID.set(brickID, storedData);
      }
    }
    return bricksByID;
  }

  shouldDecompressBrick(brick, data) {
    return this.effectiveBrickCompression(brick) === "lz4" &&
      data.byteLength < this.uncompressedByteLengthFor(brick);
  }

  uncompressedByteLengthFor(brick) {
    return brick.uncompressedByteLength ?? this.uncompressedBrickByteLength;
  }

  effectiveBrickCompression(brick) {
    const brickCompression = normalizeCompressionName(brick.compression);
    if (brickCompression && brickCompression !== "per-brick") {
      return brickCompression;
    }
    return this.datasetCompression === "per-brick" ? "lz4" : this.datasetCompression;
  }

  uploadBrick(slot, brickData) {
    const prepareStart = now();
    const origin = this.slotOrigin(slot);
    const bytesPerRow = align(this.brickSize * this.textureBytesPerVoxel, 256);
    const rowsPerImage = this.brickSize;
    const paddedData = new Uint8Array(bytesPerRow * rowsPerImage * this.brickSize);
    const sourceBytesPerRow = this.brickSize * this.bytesPerVoxel;

    for (let z = 0; z < this.brickSize; z += 1) {
      for (let y = 0; y < this.brickSize; y += 1) {
        const sourceOffset = (z * this.brickSize + y) * sourceBytesPerRow;
        const destinationOffset = (z * rowsPerImage + y) * bytesPerRow;
        if (this.bytesPerComponent === 1) {
          paddedData.set(brickData.subarray(sourceOffset, sourceOffset + sourceBytesPerRow), destinationOffset);
        } else {
          for (let x = 0; x < this.brickSize; x += 1) {
            const sourceVoxelOffset = sourceOffset + x * this.bytesPerVoxel;
            const value = brickData[sourceVoxelOffset] | (brickData[sourceVoxelOffset + 1] << 8);
            const normalizedValue = Math.min(1, Math.max(0, value / Math.max(1, this.dataRangeMax)));
            writeUInt16LE(paddedData, destinationOffset + x * this.textureBytesPerVoxel, float32ToFloat16Bits(normalizedValue));
          }
        }
      }
    }
    this.recordProfile("uploadPrepareMs", now() - prepareStart);
    this.profile.uploadedBytes += paddedData.byteLength;

    const uploadStart = now();
    this.device.queue.writeTexture(
      { texture: this.texture, origin },
      paddedData,
      { bytesPerRow, rowsPerImage },
      [this.brickSize, this.brickSize, this.brickSize]
    );
    this.recordProfile("uploadSubmitMs", now() - uploadStart);
  }

  slotOrigin(slot) {
    const x = slot % this.atlasBricksPerAxis;
    const y = Math.floor(slot / this.atlasBricksPerAxis) % this.atlasBricksPerAxis;
    const z = Math.floor(slot / (this.atlasBricksPerAxis * this.atlasBricksPerAxis));
    return {
      x: x * this.brickSize,
      y: y * this.brickSize,
      z: z * this.brickSize
    };
  }

  recordProfile(key, value) {
    if (this.profilingEnabled) {
      this.profile[key] += value;
    }
  }
}

function createAtlasProfile() {
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

function classifyBricks(manifest, transferFunction, options = {}) {
  const bricks = manifest.bricks ?? [];
  const meta = new Uint32Array(bricks.length);
  meta.fill(BI_MISSING);
  const renderMode = options.renderMode ?? 0;

  if (!transferFunction && renderMode !== 2) {
    return { meta, emptyCount: 0, childEmptyCount: 0, fullyOpaqueCount: 0 };
  }

  const range = manifest.volume?.valueRange ?? manifest.volume?.dataRange ?? [0, 255];
  const rangeMax = Math.max(1, range[1] ?? 255);
  const levels = [...(manifest.levels ?? [])].sort((a, b) => a.level - b.level);
  const childTable = buildChildTable(levels, bricks.length);
  const empty = new Array(bricks.length).fill(false);
  const fullyOpaque = new Array(bricks.length).fill(false);

  for (const brick of bricks) {
    const minValue = brick.min ?? brick.minValue ?? 0;
    const maxValue = brick.max ?? brick.maxValue ?? minValue;
    if (renderMode === 2) {
      const isoRawValue = options.isoRawValue ?? clamp(options.isoValue ?? 0.5, 0, 1) * rangeMax;
      empty[brick.index] = maxValue < isoRawValue;
      fullyOpaque[brick.index] = false;
    } else {
      empty[brick.index] = transferFunction.isRangeEmpty(minValue, maxValue, rangeMax);
      fullyOpaque[brick.index] = transferFunction.isRangeFullyOpaque(minValue, maxValue, rangeMax);
    }
  }

  for (const level of levels) {
    for (let z = 0; z < level.brickCount[2]; z += 1) {
      for (let y = 0; y < level.brickCount[1]; y += 1) {
        for (let x = 0; x < level.brickCount[0]; x += 1) {
          const index = level.firstBrick + x + y * level.brickCount[0] + z * level.brickCount[0] * level.brickCount[1];
          if (!empty[index]) {
            continue;
          }
          const children = childTable[index] ?? [];
          const childrenAreEmpty = children.every((childIndex) => meta[childIndex] === BI_CHILD_EMPTY);
          meta[index] = childrenAreEmpty ? BI_CHILD_EMPTY : BI_EMPTY;
        }
      }
    }
  }

  let emptyCount = 0;
  let childEmptyCount = 0;
  let fullyOpaqueCount = 0;
  for (let index = 0; index < meta.length; index += 1) {
    if (meta[index] === BI_EMPTY) {
      emptyCount += 1;
    } else if (meta[index] === BI_CHILD_EMPTY) {
      childEmptyCount += 1;
    }
    if (fullyOpaque[index]) {
      fullyOpaqueCount += 1;
    }
  }

  return { meta, emptyCount, childEmptyCount, fullyOpaqueCount };
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

function normalizeCompressionName(value) {
  if (value === "lz4" || value === "none" || value === "per-brick") {
    return value;
  }
  return null;
}

function formatMiB(byteCount) {
  return `${(byteCount / (1024 * 1024)).toFixed(1)} MiB`;
}

function bytesToMiB(byteCount) {
  return byteCount / (1024 * 1024);
}

function now() {
  return performance.now();
}

function buildChildTable(levels, totalBrickCount) {
  const childTable = Array.from({ length: totalBrickCount }, () => []);
  const childFactor = 2;

  for (let levelIndex = 1; levelIndex < levels.length; levelIndex += 1) {
    const prevLevel = levels[levelIndex - 1];
    const currLevel = levels[levelIndex];
    const prevSizeX = prevLevel.brickCount[0];
    const prevSizeY = prevLevel.brickCount[1];
    const prevSizeZ = prevLevel.brickCount[2];
    const prevBricksPerLayer = prevSizeX * prevSizeY;
    const prevOffset = prevLevel.firstBrick;
    const currSizeX = currLevel.brickCount[0];
    const currSizeY = currLevel.brickCount[1];
    const currSizeZ = currLevel.brickCount[2];
    const currOffset = currLevel.firstBrick;

    for (let z = 0; z < currSizeZ; z += 1) {
      for (let y = 0; y < currSizeY; y += 1) {
        for (let x = 0; x < currSizeX; x += 1) {
          const currBrickIndex = currOffset + z * currSizeX * currSizeY + y * currSizeX + x;
          const maxZ = Math.min((z + 1) * childFactor, prevSizeZ);
          const maxY = Math.min((y + 1) * childFactor, prevSizeY);
          const maxX = Math.min((x + 1) * childFactor, prevSizeX);

          for (let nz = z * childFactor; nz < maxZ; nz += 1) {
            for (let ny = y * childFactor; ny < maxY; ny += 1) {
              for (let nx = x * childFactor; nx < maxX; nx += 1) {
                childTable[currBrickIndex].push(prevOffset + nz * prevBricksPerLayer + ny * prevSizeX + nx);
              }
            }
          }
        }
      }
    }
  }

  return childTable;
}

export function decodeAppleLZ4(data, expectedLength) {
  if (data.byteLength >= 8 &&
      data[0] === 0x62 &&
      data[1] === 0x76 &&
      data[2] === 0x34 &&
      (data[3] === 0x31 || data[3] === 0x2d)) {
    return decodeAppleLZ4Stream(data, expectedLength);
  }

  return decodeLZ4Block(data, expectedLength);
}

function decodeAppleLZ4Stream(data, expectedLength) {
  const output = new Uint8Array(expectedLength);
  let sourceOffset = 0;
  let outputOffset = 0;

  while (sourceOffset < data.byteLength) {
    if (sourceOffset + 4 <= data.byteLength &&
        data[sourceOffset] === 0x62 &&
        data[sourceOffset + 1] === 0x76 &&
        data[sourceOffset + 2] === 0x34 &&
        data[sourceOffset + 3] === 0x24) {
      sourceOffset += 4;
      break;
    }

    if (sourceOffset + 8 > data.byteLength ||
        data[sourceOffset] !== 0x62 ||
        data[sourceOffset + 1] !== 0x76 ||
        data[sourceOffset + 2] !== 0x34) {
      throw new Error("Invalid Apple LZ4 block header");
    }

    const blockType = data[sourceOffset + 3];
    const uncompressedLength = readUInt32LE(data, sourceOffset + 4);
    if (outputOffset + uncompressedLength > expectedLength) {
      throw new Error(`Apple LZ4 stream exceeds expected output size ${expectedLength}`);
    }

    if (blockType === 0x31) {
      if (sourceOffset + 12 > data.byteLength) {
        throw new Error("Apple LZ4 compressed block header is incomplete");
      }
      const compressedLength = readUInt32LE(data, sourceOffset + 8);
      sourceOffset += 12;

      if (sourceOffset + compressedLength > data.byteLength) {
        throw new Error("Apple LZ4 compressed block exceeds source size");
      }

      const decodedLength = decodeLZ4BlockInto(
        data.subarray(sourceOffset, sourceOffset + compressedLength),
        output,
        outputOffset,
        uncompressedLength
      );
      outputOffset += decodedLength;
      sourceOffset += compressedLength;
    } else if (blockType === 0x2d) {
      sourceOffset += 8;

      if (sourceOffset + uncompressedLength > data.byteLength) {
        throw new Error("Apple LZ4 raw block exceeds source size");
      }

      output.set(data.subarray(sourceOffset, sourceOffset + uncompressedLength), outputOffset);
      outputOffset += uncompressedLength;
      sourceOffset += uncompressedLength;
    } else {
      throw new Error("Invalid Apple LZ4 block type");
    }
  }

  if (outputOffset !== expectedLength) {
    throw new Error(`Apple LZ4 stream decoded ${outputOffset} bytes, expected ${expectedLength}`);
  }
  return output;
}

function decodeLZ4Block(source, expectedLength) {
  const output = new Uint8Array(expectedLength);
  decodeLZ4BlockInto(source, output, 0, expectedLength);
  return output;
}

function decodeLZ4BlockInto(source, output, startOffset, expectedLength) {
  let inputOffset = 0;
  let outputOffset = startOffset;
  const outputEnd = startOffset + expectedLength;

  const readLength = (initialLength) => {
    let length = initialLength;
    if (initialLength === 15) {
      while (inputOffset < source.byteLength) {
        const value = source[inputOffset];
        inputOffset += 1;
        length += value;
        if (value !== 255) {
          break;
        }
      }
    }
    return length;
  };

  while (inputOffset < source.byteLength && outputOffset < outputEnd) {
    const token = source[inputOffset];
    inputOffset += 1;

    const literalLength = readLength(token >> 4);
    if (inputOffset + literalLength > source.byteLength) {
      throw new Error("LZ4 literal run exceeds source size");
    }
    if (outputOffset + literalLength > outputEnd) {
      throw new Error("LZ4 literal run exceeds output size");
    }
    output.set(source.subarray(inputOffset, inputOffset + literalLength), outputOffset);
    inputOffset += literalLength;
    outputOffset += literalLength;

    if (inputOffset >= source.byteLength || outputOffset >= outputEnd) {
      break;
    }
    if (inputOffset + 2 > source.byteLength) {
      throw new Error("LZ4 block ends before match offset");
    }

    const offset = source[inputOffset] | (source[inputOffset + 1] << 8);
    inputOffset += 2;
    if (offset === 0 || offset > outputOffset) {
      throw new Error("LZ4 match offset is invalid");
    }

    const matchLength = readLength(token & 0x0f) + 4;
    if (outputOffset + matchLength > outputEnd) {
      throw new Error("LZ4 match exceeds output size");
    }

    let matchOffset = outputOffset - offset;
    for (let index = 0; index < matchLength; index += 1) {
      output[outputOffset] = output[matchOffset];
      outputOffset += 1;
      matchOffset += 1;
    }
  }

  if (outputOffset !== outputEnd) {
    throw new Error(`LZ4 decoded ${outputOffset - startOffset} bytes, expected ${expectedLength}`);
  }
  return expectedLength;
}

function readUInt32LE(data, offset) {
  return (data[offset] |
    (data[offset + 1] << 8) |
    (data[offset + 2] << 16) |
    (data[offset + 3] << 24)) >>> 0;
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
