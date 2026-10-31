import Metal
import Foundation

/**
 An error type representing failures during page operations in the volume atlas.
 */
enum PageError: Error {
  /// Indicates that the working set is too large.
  case workingSetTooLarge(Int, Int)
  /// Indicates that paging in too many bricks would exceed the capacity.
  case pagingInTooManyBricks(Int, Int)

  /// A localized description of the error.
  var errorDescription: String? {
    switch self {
      case .workingSetTooLarge(let workingset, let count):
        return "Page table overflow, working set (\(workingset) is too large for the " +
        "page table (max \(count))"
      case .pagingInTooManyBricks(let brickCount, let count):
        return "Page table overflow, paging in (\(brickCount)) would exceed the " +
        "page table capacity (\(count))"
    }
  }
}

/**
 A structure containing metadata for a page in the texture atlas.

 Each PageMetadata records the page ID, the associated brick ID, the arrival time
 (as an index), and a backup of the previous arrival index.
 */
struct PageMetadata {
  let pageID: Int
  var brickID: Int
  var arrivalIndex: Int
  var previousIndex: Int

  /**
   Initializes a new PageMetadata instance.

   - Parameters:
   - pageID: The identifier for the page.
   - brickID: The brick identifier.
   - arrivalIndex: The arrival index timestamp.
   */
  init(pageID: Int, brickID: Int, arrivalIndex: Int) {
    self.pageID = pageID
    self.brickID = brickID
    self.arrivalIndex = arrivalIndex
    self.previousIndex = arrivalIndex
  }

  /**
   Checks if the page contains a visible brick.

   - Returns: True if the arrival index is greater than zero; otherwise, false.
   */
  func containsVisibleBrick() -> Bool {
    return arrivalIndex > 0
  }

  /**
   Flags the page as empty.

   This method saves the current arrivalIndex to previousIndex and sets the arrivalIndex to zero.
   */
  mutating func flagEmpty() {
    self.previousIndex = arrivalIndex
    arrivalIndex = 0
  }

  /**
   Reactivates the page if it contains the specified brick.

   - Parameter brickID: The brick ID to check.
   - Returns: True if the page is reactivated; otherwise, false.
   */
  mutating func reactivate(ifItContains brickID: Int) -> Bool {
    if self.brickID != brickID {
      return false
    }
    self.arrivalIndex = previousIndex
    return true
  }

  /**
   Sets new values for the brick ID and arrival index.

   - Parameters:
   - brickID: The new brick identifier.
   - arrivalIndex: The new arrival index.
   */
  mutating func set(brickID: Int, arrivalIndex: Int) {
    self.brickID = brickID
    self.arrivalIndex = arrivalIndex
  }
}

/**
 An error type for volume atlas operations.
 */
enum VolumeAtlasError: Error, LocalizedError {
  /// Indicates that the 3D texture atlas creation failed.
  case failedToCreateTexture
  case unsupportedFormat(bytesPerComponent: Int, componentCount: Int)

  /// A localized description of the error.
  var errorDescription: String? {
    switch self {
      case .failedToCreateTexture:
        return "Failed to create the 3D texture atlas. Make sure the device has " +
        "enough memory and supports the requested format."
      case .unsupportedFormat(let bytesPerComponent, let componentCount):
        return "Unsupported volume format: \(componentCount) channel(s) with " +
        "\(bytesPerComponent * 8) bits per channel."
    }
  }
}

/**
 A VolumeAtlas manages a 3D texture atlas for paged-in brick data from a volumetric dataset.

 It creates and manages GPU textures, metadata buffers, and level-of-detail tables. It also
 interacts with an asynchronous emptiness updater to update the visibility state of bricks.
 */
class VolumeAtlas {
  private var device: MTLDevice
  /// The 3D texture atlas storing voxel data.
  var atlasTexture: MTLTexture!
  private var secondaryAtlasTexture: MTLTexture?
  private var primaryUploadStorage: [UInt8] = []
  private var secondaryUploadStorage: [UInt8] = []
  private var levelTable: MTLBuffer!
  private var metaBuffer: MTLBuffer!
  private var metaStorage: [UInt32] = []
  private var pageMetadata: [PageMetadata] = []
  private var brickToPage: [Int: Int] = [:]
  private var purgeDataOnNextPage = false
  private var elementsInBuffer = 0

  /// An optional logger for debug and error messages.
  private let logger: LoggerBase?

  private var pageFrame = 1 // Must start at 1, as 0 signals "empty"
  private var observedContentRevision: UInt64 = 0
  private var observedBrushGeneration: UInt64 = 0
  private var pendingEditedBrickIDs: Set<Int> = []
  private var brushRenderer: VolumeAtlasBrushRenderer?
  private var gpuBrushAttached = false
  private var pageEditRevisions: [Int: UInt64] = [:]
  private var pendingGPUFrame: (command: MTLCommandBuffer, revisions: [Int: (brick: Int, revision: UInt64)])?
  private var gpuBrushSource: BorgVRVolumeGPUBrushSource? { borgData as? BorgVRVolumeGPUBrushSource }
  private var brickStorage = (0, 0, 0)
  private var subbrickCache: VolumeAtlasSubbrickCache?
  private var subbrickSkippingEnabled = false
  private var subbrickSetupFailed = false

  private var borgData: BORGVRDatasetProtocol
  var isContentReady: Bool { borgData.isContentReady }
  private var borgBuffer: UnsafeMutablePointer<UInt8>

  private var asyncEmptinessUpdater: AsyncEmptinessUpdater

  // Cached values.
  private lazy var bytesPerPixel: Int = {
    let metadata = self.borgData.getMetadata()
    return metadata.bytesPerComponent * metadata.componentCount
  }()
  private lazy var bytesPerRow: Int = {
    let metadata = self.borgData.getMetadata()
    return metadata.brickSize * bytesPerPixel
  }()
  private lazy var bytesPerImage: Int = {
    let metadata = self.borgData.getMetadata()
    return metadata.brickSize * bytesPerRow
  }()

  /**
   Initializes a new VolumeAtlas.

   - Parameters:
   - device: The Metal device.
   - maxMemory: The maximum memory available for the atlas.
   - borgData: The dataset providing brick data.
   - transferFunction: The transfer function used for emptiness testing.
   - isoValue: The normalized isovalue.
   - Throws: VolumeAtlasError if texture creation fails.
   */
  init(device: MTLDevice, maxMemory: Int, borgData: BORGVRDatasetProtocol,
       transferFunctions: [TransferFunction1D], isoValue: Float,
       logger: LoggerBase? = nil) throws {

    let metadata = borgData.getMetadata()
    let pixelFormats = try VolumeAtlas.getPixelFormats(
      bytesPerComponent: metadata.bytesPerComponent,
      componentCount: metadata.componentCount
    )

    self.device = device
    self.borgData = borgData
    self.borgBuffer = borgData.allocateBrickBuffer()
    self.logger = logger
    self.asyncEmptinessUpdater = AsyncEmptinessUpdater(
      borgData: borgData,
      transferFunctions: transferFunctions,
      isoValue: isoValue,
      logger: logger
    )

    let brickSize = metadata.brickSize
    let bytesPerVoxel = VolumeAtlas.textureBytesPerVoxel(
      bytesPerComponent: metadata.bytesPerComponent,
      componentCount: metadata.componentCount
    )
    let minimumAtlasMemory = max(1, brickSize * brickSize * brickSize * bytesPerVoxel)
    var atlasBudget = max(maxMemory, minimumAtlasMemory)
    var atlasLayout: (width: Int, height: Int, depth: Int, inCoreBrickCount: Int)?
    var createdAtlasTexture: MTLTexture?

    while atlasBudget >= minimumAtlasMemory {
      let layout = VolumeAtlas.computeAtlasSize(
        maxMemory: atlasBudget,
        maxBrickCount: metadata.brickMetadata.count,
        brickSize: metadata.brickSize,
        bytesPerComponent: metadata.bytesPerComponent,
        componentCount: metadata.componentCount
      )

      let atlasDescriptor = MTLTextureDescriptor()
      atlasDescriptor.textureType = .type3D
      atlasDescriptor.pixelFormat = pixelFormats.primary
      atlasDescriptor.width = layout.width
      atlasDescriptor.height = layout.height
      atlasDescriptor.depth = layout.depth
      atlasDescriptor.usage = [.shaderRead, .shaderWrite]
      atlasDescriptor.storageMode = .shared

      let primaryTexture = device.makeTexture(descriptor: atlasDescriptor)
      var secondaryTexture: MTLTexture?
      if let secondaryFormat = pixelFormats.secondary {
        atlasDescriptor.pixelFormat = secondaryFormat
        secondaryTexture = device.makeTexture(descriptor: atlasDescriptor)
      }
      if let atlasTexture = primaryTexture,
         pixelFormats.secondary == nil || secondaryTexture != nil {
        atlasLayout = layout
        createdAtlasTexture = atlasTexture
        self.secondaryAtlasTexture = secondaryTexture
        if atlasBudget < maxMemory {
          logger?.warning(
            "Atlas allocation fell back from \(maxMemory / 1024 / 1024) MB " +
            "to \(atlasBudget / 1024 / 1024) MB."
          )
        }
        break
      }

      let nextBudget = atlasBudget / 2
      logger?.warning(
        "Atlas allocation failed for \(atlasBudget / 1024 / 1024) MB; " +
        "retrying with \(nextBudget / 1024 / 1024) MB."
      )
      atlasBudget = nextBudget
    }

    guard let atlasLayout, let createdAtlasTexture else {
      throw VolumeAtlasError.failedToCreateTexture
    }
    let width = atlasLayout.width
    let height = atlasLayout.height
    let depth = atlasLayout.depth
    let inCoreBrickCount = atlasLayout.inCoreBrickCount
    self.brickStorage = (width / brickSize, height / brickSize, depth / brickSize)
    self.atlasTexture = createdAtlasTexture
    if gpuBrushSource != nil {
      do {
        brushRenderer = try VolumeAtlasBrushRenderer(device: device, metadata: metadata)
      } catch {
        logger?.warning("GPU volume brushes unavailable; using CPU editing: \(error.localizedDescription)")
      }
    }

    // Create metadata buffer.
    let brickCount = metadata.brickMetadata.count
    metaStorage = [UInt32](
      repeating: UInt32(BrickIDFlags.BI_MISSING.rawValue),
      count: brickCount
    )

    let alignedMetaStorageCount = (MemoryLayout<UInt32>.stride * brickCount + 255) & -256
    self.metaBuffer = device.makeBuffer(length: alignedMetaStorageCount,
                                        options: .storageModeShared)
    self.metaBuffer.contents().copyMemory(
      from: metaStorage,
      byteCount: MemoryLayout<UInt32>.stride * brickCount
    )

    pageMetadata = (0..<inCoreBrickCount).map { index in
      return PageMetadata(pageID: index, brickID: -1, arrivalIndex: 0)
    }

    // Create LOD Offset Table.
    let levelMetadata = metadata.levelMetadata
    let levelStorage = (0..<levelMetadata.count).map { index in

      let fractionalBrickLayout = SIMD3<Float>(
        Float(levelMetadata[index].size.x) / Float(
          metadata.brickSize - 2 * metadata.overlap
        ),
        Float(levelMetadata[index].size.y) / Float(
          metadata.brickSize - 2 * metadata.overlap
        ),
        Float(levelMetadata[index].size.z) / Float(
          metadata.brickSize - 2 * metadata.overlap
        )
      )

      return LevelData(
        bricksX: UInt32(levelMetadata[index].totalBricks.x),
        bricksXTimesBricksY: UInt32(levelMetadata[index].totalBricks.x *
                                    levelMetadata[index].totalBricks.y),
        prevBricks: UInt32(levelMetadata[index].prevBricks),
        fractionalBrickLayout: fractionalBrickLayout
      )
    }

    let alignedLevelMetadataSize = AlignedBuffer.alignedSize(
      for: LevelData.self,
      count: levelMetadata.count
    )
    self.levelTable = self.device.makeBuffer(
      length: alignedLevelMetadataSize,
      options: .storageModeShared
    )
    self.levelTable.contents().copyMemory(
      from: levelStorage,
      byteCount: MemoryLayout<LevelData>.stride * levelMetadata.count
    )

    logger?.dev("Paging in lowest-res brick")

    // Ensure the lowest-res single brick is paged in at position 0, so it always is guaranteed to be resident
    let initialRevision = gpuBrushSource?.gpuReadableRevision(index: brickCount - 1) ?? 0
    try borgData.getFirstBrick(outputBuffer: borgBuffer)
    replaceAtlasBrick(x: 0, y: 0, z: 0, data: borgBuffer)
    let lastBrickIndex = brickCount - 1
    metaStorage[lastBrickIndex] = UInt32(0 + BrickIDFlags.BI_FLAG_COUNT.rawValue)
    brickToPage[lastBrickIndex] = 0
    pageMetadata[0].set(brickID: lastBrickIndex, arrivalIndex: Int.max - 1)
    pageEditRevisions[0] = initialRevision

    updateMetaBuffer()

    logger?.dev("VolumeAtlas initialized")
    borgData.updateResidentBrickIDs(Set(pageMetadata.map(\.brickID).filter { $0 >= 0 }))
    if brushRenderer != nil {
      gpuBrushSource?.attachGPUBrushRenderer()
      gpuBrushAttached = true
    }
  }

  deinit {
    if gpuBrushAttached { gpuBrushSource?.detachGPUBrushRenderer() }
    asyncEmptinessUpdater.terminateBackgroundTask()
    borgBuffer.deallocate()
    logger?.dev("VolumeAtlas deinitialized")
  }

  /**
   Updates the CPU-side metadata buffer from metaStorage.
   */
  private func updateMetaBuffer() {
    _ = metaStorage.withUnsafeBytes { srcPointer in
      memcpy(metaBuffer.contents(),
             srcPointer.baseAddress,
             metaStorage.count * MemoryLayout<UInt32>.stride)
    }
  }

  /**
   Replaces a subregion of the atlas texture with new brick data.

   - Parameters:
   - x: The x-coordinate (in brick units) within the atlas.
   - y: The y-coordinate (in brick units) within the atlas.
   - z: The z-coordinate (in brick units) within the atlas.
   - data: A pointer to the brick data.
   */
  private func replaceAtlasBrick(x: Int, y: Int, z: Int,
                                 data: UnsafeMutablePointer<UInt8>) {
    subbrickCache?.invalidate(page: x + brickStorage.0 * (y + brickStorage.1 * z))
    let metadata = borgData.getMetadata()
    let brickSize = metadata.brickSize
    let region = MTLRegion(
      origin: MTLOrigin(x: x * brickSize, y: y * brickSize, z: z * brickSize),
      size: MTLSize(width: brickSize, height: brickSize, depth: brickSize)
    )
    let voxelCount = brickSize * brickSize * brickSize
    if metadata.bytesPerComponent == 1 && metadata.componentCount == 3 {
      let outputCount = voxelCount * 4
      if primaryUploadStorage.count != outputCount {
        primaryUploadStorage = [UInt8](repeating: 0, count: outputCount)
      }
      for voxel in 0..<voxelCount {
        let source = voxel * 3
        let destination = voxel * 4
        primaryUploadStorage[destination] = data[source]
        primaryUploadStorage[destination + 1] = data[source + 1]
        primaryUploadStorage[destination + 2] = data[source + 2]
        primaryUploadStorage[destination + 3] = 0
      }
      replace(
        texture: atlasTexture,
        region: region,
        bytes: primaryUploadStorage,
        bytesPerVoxel: 4,
        brickSize: brickSize
      )
      return
    }

    if metadata.bytesPerComponent == 2 && metadata.componentCount >= 3 {
      let secondaryBytesPerVoxel = (metadata.componentCount - 2) * 2
      let primaryCount = voxelCount * 4
      let secondaryCount = voxelCount * secondaryBytesPerVoxel
      if primaryUploadStorage.count != primaryCount {
        primaryUploadStorage = [UInt8](repeating: 0, count: primaryCount)
      }
      if secondaryUploadStorage.count != secondaryCount {
        secondaryUploadStorage = [UInt8](repeating: 0, count: secondaryCount)
      }
      let sourceBytesPerVoxel = metadata.componentCount * 2
      for voxel in 0..<voxelCount {
        let source = voxel * sourceBytesPerVoxel
        let primaryDestination = voxel * 4
        for byte in 0..<4 {
          primaryUploadStorage[primaryDestination + byte] = data[source + byte]
        }
        let secondaryDestination = voxel * secondaryBytesPerVoxel
        for byte in 0..<secondaryBytesPerVoxel {
          secondaryUploadStorage[secondaryDestination + byte] = data[source + 4 + byte]
        }
      }
      replace(
        texture: atlasTexture,
        region: region,
        bytes: primaryUploadStorage,
        bytesPerVoxel: 4,
        brickSize: brickSize
      )
      if let secondaryAtlasTexture {
        replace(
          texture: secondaryAtlasTexture,
          region: region,
          bytes: secondaryUploadStorage,
          bytesPerVoxel: secondaryBytesPerVoxel,
          brickSize: brickSize
        )
      }
      return
    }

    atlasTexture.replace(
      region: region,
      mipmapLevel: 0,
      slice: 0,
      withBytes: data,
      bytesPerRow: bytesPerRow,
      bytesPerImage: bytesPerImage
    )
  }

  private func replace(
    texture: MTLTexture,
    region: MTLRegion,
    bytes: [UInt8],
    bytesPerVoxel: Int,
    brickSize: Int
  ) {
    bytes.withUnsafeBytes { rawBytes in
      guard let baseAddress = rawBytes.baseAddress else { return }
      texture.replace(
        region: region,
        mipmapLevel: 0,
        slice: 0,
        withBytes: baseAddress,
        bytesPerRow: brickSize * bytesPerVoxel,
        bytesPerImage: brickSize * brickSize * bytesPerVoxel
      )
    }
  }

  /**
   Binds the atlas texture and metadata buffer to the specified fragment shader indices.

   - Parameters:
   - encoder: The MTLRenderCommandEncoder.
   - atlasIndex: The texture index for the atlas.
   - metaIndex: The buffer index for the metadata.
   - levelIndex: The buffer index for the LOD offset table.
   */
  func bind(to encoder: MTLRenderCommandEncoder,
            atlasIndex: Int, metaIndex: Int, levelIndex: Int) {
    encoder.setFragmentTexture(atlasTexture, index: atlasIndex)
    encoder.setFragmentTexture(
      secondaryAtlasTexture ?? atlasTexture,
      index: TextureIndex.volumeAtlasSecondary.rawValue
    )
    encoder.setFragmentBuffer(metaBuffer, offset: 0, index: metaIndex)
    encoder.setFragmentBuffer(levelTable, offset: 0, index: levelIndex)
    encoder.setFragmentBuffer(subbrickCache?.masks ?? metaBuffer, offset: 0,
      index: FragmentBufferIndex.subbrickMasks.rawValue)
    var enabled: UInt32 = subbrickSkippingEnabled ? 1 : 0
    encoder.setFragmentBytes(&enabled, length: MemoryLayout<UInt32>.size,
      index: FragmentBufferIndex.subbrickEnabled.rawValue)
  }

  func prepareSubbrickSkipping(commandBuffer: MTLCommandBuffer,
                              transferFunctions: [TransferFunction1D], enabled: Bool,
                              isoValue: Float? = nil) throws {
    subbrickSkippingEnabled = false
    guard enabled else { subbrickSetupFailed = false; return }
    let metadata = borgData.getMetadata()
    let count = VolumeAtlasSubbrickCache.divisions(brickSize: metadata.brickSize, overlap: metadata.overlap)
    guard count > 1, !subbrickSetupFailed else { return }
    if subbrickCache == nil {
      do {
        subbrickCache = try VolumeAtlasSubbrickCache(device: device, metadata: metadata,
                                                   capacity: pageMetadata.count, divisions: count)
      } catch {
        // Keep rendering normally instead of retrying a failed allocation/compiler every frame.
        subbrickSetupFailed = true
        throw error
      }
    }
    subbrickSkippingEnabled = subbrickCache?.prepare(command: commandBuffer, primary: atlasTexture,
      secondary: secondaryAtlasTexture, pages: Array(Set(brickToPage.values)),
      transferFunctions: transferFunctions, isoValue: isoValue) == true
  }

  /// Called before opening any render encoder. All brush work uses the frame's
  /// existing command buffer, so no extra submissions or GPU/CPU waits are needed.
  func prepareFrame(commandBuffer: MTLCommandBuffer) {
    finishGPUBrushFrame()
    if let source = gpuBrushSource, observedBrushGeneration != source.gpuBrushGeneration {
      observedBrushGeneration = source.gpuBrushGeneration
      pageEditRevisions.removeAll()
      pendingEditedBrickIDs.formUnion(brickToPage.keys)
    }
    if let newMetaStorage = asyncEmptinessUpdater.inCoreDataHasChanged() {
      metaStorage = newMetaStorage
      updateMetaBuffer()
    }
    refreshEditedBricks()
    guard let brushRenderer, let source = gpuBrushSource else { return }
    let history = source.gpuBrushHistory()
    guard let first = history.first, let latest = history.last else { return }
    let metadata = borgData.getMetadata()
    let candidates = brickToPage.filter { _, page in
      guard pageEditRevisions[page] != nil else { return false }
      let revision = pageEditRevisions[page] ?? 0
      return revision < latest.revision && revision >= first.revision - 1
    }
    guard let earliest = candidates.values.map({ pageEditRevisions[$0] ?? 0 }).min(),
          let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
    encoder.label = "Volume brushes: all resident LODs"
    let batches = history.filter { $0.revision > earliest }.map { brushRenderer.prepare($0) }
    var revisions: [Int: (brick: Int, revision: UInt64)] = [:]
    for (id, page) in candidates {
      var revision = pageEditRevisions[page] ?? 0
      let (x, y, z) = IDToCoords(pageIndex: page)
      for prepared in batches {
        guard let batch = prepared else { break }
        guard batch.revision > revision else { continue }
        guard brushRenderer.encode(batch, brickID: id,
          pageOrigin: SIMD3(x, y, z) &* metadata.brickSize,
          primary: atlasTexture, secondary: secondaryAtlasTexture, source: source,
          encoder: encoder) else { break }
        revision = batch.revision
      }
      revisions[page] = (id, revision)
      subbrickCache?.invalidate(page: page)
    }
    encoder.endEncoding()
    pendingGPUFrame = (commandBuffer, revisions)
  }

  private func finishGPUBrushFrame() {
    guard let pending = pendingGPUFrame else { return }
    // Encoding is not execution: a frame can be abandoned before commit. Only
    // acknowledge successful GPU work, otherwise replay the idempotent operations.
    if pending.command.status == .completed {
      for (page, update) in pending.revisions where pageMetadata[page].brickID == update.brick {
        pageEditRevisions[page] = max(pageEditRevisions[page] ?? 0, update.revision)
      }
    }
    pendingGPUFrame = nil
  }

  private func refreshEditedBricks() {
    let revision = borgData.contentRevision
    let changed = revision != observedContentRevision
    if changed {
      let ids = borgData.changedBrickIDs(since: observedContentRevision)
      observedContentRevision = revision
      for id in ids where metaStorage.indices.contains(id) {
        let empty = borgData.visibilityMetadata(index: id).map {
          asyncEmptinessUpdater.brickIsEmpty(brickMetadata: $0)
        } ?? false
        if let page = brickToPage[id] {
          pendingEditedBrickIDs.insert(id)
          // A restore can make a previously empty resident page visible immediately.
          metaStorage[id] = empty ? UInt32(BrickIDFlags.BI_EMPTY.rawValue)
            : UInt32(page) + UInt32(BrickIDFlags.BI_FLAG_COUNT.rawValue)
        }
        else {
          metaStorage[id] = UInt32(empty ? BrickIDFlags.BI_EMPTY.rawValue : BrickIDFlags.BI_MISSING.rawValue)
        }
      }
    }
    guard changed || !pendingEditedBrickIDs.isEmpty else { return }
    var uploaded = false
    for id in Array(pendingEditedBrickIDs) {
      guard let page = brickToPage[id], pageMetadata[page].brickID == id else {
        pendingEditedBrickIDs.remove(id)
        continue
      }
      do {
        let readableRevision = gpuBrushSource?.gpuReadableRevision(index: id)
        if brushRenderer != nil, readableRevision == nil || readableRevision! < (pageEditRevisions[page] ?? 0) {
          continue
        }
        let fineCount = borgData.getMetadata().levelMetadata.dropFirst().first?.prevBricks ?? metaStorage.count
        if brushRenderer != nil, id < fineCount, readableRevision == pageEditRevisions[page] {
          // The GPU already has these exact voxels; only min/max/emptiness changed.
          pendingEditedBrickIDs.remove(id)
          continue
        }
        try borgData.getBrick(index: id, outputBuffer: borgBuffer)
        let (x, y, z) = IDToCoords(pageIndex: page)
        replaceAtlasBrick(x: x, y: y, z: z, data: borgBuffer)
        pageEditRevisions[page] = readableRevision ?? 0
        let empty = borgData.visibilityMetadata(index: id).map {
          asyncEmptinessUpdater.brickIsEmpty(brickMetadata: $0)
        } ?? false
        metaStorage[id] = empty ? UInt32(BrickIDFlags.BI_EMPTY.rawValue)
          : UInt32(page) + UInt32(BrickIDFlags.BI_FLAG_COUNT.rawValue)
        uploaded = true
        pendingEditedBrickIDs.remove(id)
      } catch {
        // The old page remains valid until the complete replacement is ready.
      }
    }
    guard changed || uploaded else { return }
    asyncEmptinessUpdater.updateMetadata(metaStorage: metaStorage, brickToPage: brickToPage,
                                        pageMetadata: pageMetadata)
    asyncEmptinessUpdater.invalidateDataset()
    updateMetaBuffer()
  }

  /**
   Determines the Metal pixel format based on the number of bytes per component and
   the number of components per voxel.

   - Parameters:
   - bytesPerComponent: The number of bytes per voxel component.
   - componentCount: The number of components per voxel.
   - Returns: The corresponding MTLPixelFormat.
   */
  static func getPixelFormats(
    bytesPerComponent: Int,
    componentCount: Int
  ) throws -> (primary: MTLPixelFormat, secondary: MTLPixelFormat?) {
    switch (bytesPerComponent, componentCount) {
      case (1, 1): return (.r8Unorm, nil)
      case (1, 2): return (.rg8Unorm, nil)
      case (1, 3), (1, 4): return (.rgba8Unorm, nil)
      case (2, 1): return (.rg8Unorm, nil)
      case (2, 2): return (.rgba8Unorm, nil)
      case (2, 3): return (.rgba8Unorm, .rg8Unorm)
      case (2, 4): return (.rgba8Unorm, .rgba8Unorm)
      // A scalar UInt32 is stored byte-for-byte in RGBA8. The shader combines
      // the four filtered UNORM channels back into one normalized scalar.
      case (4, 1): return (.rgba8Unorm, nil)
      default:
        throw VolumeAtlasError.unsupportedFormat(
          bytesPerComponent: bytesPerComponent,
          componentCount: componentCount
        )
    }
  }

  static func textureBytesPerVoxel(bytesPerComponent: Int, componentCount: Int) -> Int {
    if bytesPerComponent == 1 && componentCount == 3 {
      return 4
    }
    return bytesPerComponent * componentCount
  }

  /**
   Converts a page index to 3D atlas coordinates.

   - Parameter pageIndex: The page index.
   - Returns: A tuple (x, y, z) representing the coordinates in the atlas.
   */
  private func IDToCoords(pageIndex: Int) -> (Int, Int, Int) {
    let x = pageIndex % brickStorage.0
    let y = (pageIndex / brickStorage.0) % brickStorage.1
    let z = pageIndex / (brickStorage.0 * brickStorage.1)
    return (x, y, z)
  }

  func purge() {
    purgeDataOnNextPage = true
    try? pageIn(IDs:[])
  }

  /**
   Updates brick emptiness using the provided transfer function.

   - Parameter transferFunction: The transfer function for emptiness computation.
   */
  func updateEmptiness(transferFunctions: [TransferFunction1D]) {
    asyncEmptinessUpdater.updateTransferFunctions(transferFunctions)
  }

  /**
   Updates brick emptiness using the provided isovalue.

   - Parameter isoValue: The normalized isovalue.
   */
  func updateEmptiness(isoValue: Float) {
    asyncEmptinessUpdater.updateIsoValue(isoValue: isoValue)
  }

  /**
   Returns the total capacity (number of pages) in the atlas.

   - Returns: The number of pages.
   */
  func getCapacity() -> Int {
    return pageMetadata.count
  }

  /**
   Pages in bricks specified by their IDs into the atlas.

   For each brick, if it is not already paged in and is not empty,
   the brick data is loaded, metadata updated, and the atlas texture is replaced.

   - Parameter IDs: An array of brick IDs to page in.
   - Throws: A PageError if the working set exceeds capacity.
   */
  func pageIn(IDs: [Int]) throws {
    finishGPUBrushFrame()
    var incompleteIndex = 0
    let BI_MISSING = UInt32(BrickIDFlags.BI_MISSING.rawValue)
    let BI_EMPTY = UInt32(BrickIDFlags.BI_EMPTY.rawValue)
    let BI_FLAG_COUNT = UInt32(BrickIDFlags.BI_FLAG_COUNT.rawValue)

    let metadata = borgData.getMetadata()

    if purgeDataOnNextPage {
      let workIngSetSize = metadata.brickSize*metadata.brickSize*metadata.brickSize*metadata.componentCount*metadata.bytesPerComponent*elementsInBuffer

      logger?.dev("Purging atlas data. Elements PREVIOUSLY in buffer: \(elementsInBuffer) size of the working set: \(Float(workIngSetSize)/Float(1024*1024)) MB")
      for index in 0..<metaStorage.count-1 {
        if metaStorage[index] >= BI_FLAG_COUNT {
          metaStorage[index] = BI_MISSING
        }
      }
      purgeDataOnNextPage = false
      elementsInBuffer = 0
      let lastBrickIndex = metadata.brickMetadata.count - 1
      brickToPage.removeAll()
      brickToPage[lastBrickIndex] = 0

      for index in 1..<pageMetadata.count {
        pageMetadata[index] = PageMetadata(pageID: index, brickID: -1, arrivalIndex: 0)
      }
    }


    let sortedIndices = pageMetadata
      .enumerated()
      .sorted {
        if $0.element.arrivalIndex == $1.element.arrivalIndex {
          return $0.element.previousIndex < $1.element.previousIndex
        }
        return $0.element.arrivalIndex < $1.element.arrivalIndex
      }
      .map { $0.offset }

    borgData.newRequest()

    var insertionIndex = 0
    for newBrickID in IDs {
      if newBrickID >= metaStorage.count {
        logger?.dev("Received invalid brick ID \(newBrickID)")
        continue
      }

      if metaStorage[newBrickID] != BI_MISSING {
        continue
      }
      
      if let effectiveMetadata = borgData.visibilityMetadata(index: newBrickID),
         asyncEmptinessUpdater.brickIsEmpty(brickMetadata: effectiveMetadata) {
        metaStorage[newBrickID] = BI_EMPTY
        continue
      }

      if let prevPage = brickToPage[newBrickID] {
        if self.pageMetadata[prevPage].reactivate(ifItContains: newBrickID) {
          metaStorage[newBrickID] = UInt32(prevPage) + BI_FLAG_COUNT
          elementsInBuffer += 1
          continue
        } else {
          brickToPage[newBrickID] = nil
        }
      }

      let readableRevision = gpuBrushSource?.gpuReadableRevision(index: newBrickID) ?? 0
      do {
        try borgData.getBrick(index: newBrickID, outputBuffer: borgBuffer)
      } catch BORGVRDataError.brickNotYetAvailable {
        // the brick source is in async mode and the brick is not ready yet
        continue
      } catch {
        continue
      }

      let insertionPos = sortedIndices[insertionIndex]
      insertionIndex += 1

      // pageMetadata.count-2 makes sure we never touch the one brick in the
      // lowest resolution that we paged-in at the start
      guard insertionIndex <= pageMetadata.count - 2 else {
        incompleteIndex = insertionIndex
        break
      }

      // Update Brick meta data
      if pageMetadata[insertionPos].containsVisibleBrick() {
        metaStorage[pageMetadata[insertionPos].brickID] = BI_MISSING
      } else {
        elementsInBuffer+=1
      }
      let pageIndex = pageMetadata[insertionPos].pageID
      let previousBrickID = pageMetadata[insertionPos].brickID
      if brickToPage[previousBrickID] == pageIndex { brickToPage[previousBrickID] = nil }
      pageMetadata[insertionPos].set(brickID: newBrickID, arrivalIndex: pageFrame)
      brickToPage[newBrickID] = pageIndex
      metaStorage[newBrickID] = UInt32(pageIndex) + BI_FLAG_COUNT

      let (x, y, z) = IDToCoords(pageIndex: pageIndex)
      replaceAtlasBrick(x: x, y: y, z: z, data: borgBuffer)
      pageEditRevisions[pageIndex] = readableRevision
    }

    asyncEmptinessUpdater.updateMetadata(metaStorage: metaStorage,
                                         brickToPage: brickToPage,
                                         pageMetadata: pageMetadata)
    borgData.updateResidentBrickIDs(Set(pageMetadata.map(\.brickID).filter { $0 >= 0 }))
    updateMetaBuffer()
    pageFrame += 1

    if incompleteIndex != 0 {
      throw PageError.workingSetTooLarge(incompleteIndex, pageMetadata.count)
    }

  }

  /**
   Computes the atlas size based on available memory, brick count, brick size, and voxel format.

   - Parameters:
   - maxMemory: Maximum memory available for the atlas.
   - maxBrickCount: Total number of bricks.
   - brickSize: The size (edge length) of each brick.
   - bytesPerComponent: Number of bytes per voxel component.
   - componentCount: Number of components per voxel.
   - Returns: A tuple (width, height, depth, inCoreBrickCount) representing the atlas dimensions.
   */
  static func computeAtlasSize(maxMemory: Int, maxBrickCount: Int,
                               brickSize: Int, bytesPerComponent: Int,
                               componentCount: Int) -> (width: Int,
                                                        height: Int,
                                                        depth: Int,
                                                        inCoreBrickCount: Int) {
    let bytesPerVoxel = textureBytesPerVoxel(
      bytesPerComponent: bytesPerComponent,
      componentCount: componentCount
    )
    let brickVolume = brickSize * brickSize * brickSize
    let brickMemory = brickVolume * bytesPerVoxel

    let maxBricks = min(maxBrickCount, maxMemory / brickMemory)

    let initialSize = intCubeRoot(maxBricks)

    var numBricksX = initialSize
    var numBricksY = initialSize
    var numBricksZ = initialSize

    var totalBricks = numBricksX * numBricksY * numBricksZ
    while totalBricks < maxBricks {
      if numBricksX <= numBricksY && numBricksX <= numBricksZ {
        numBricksX += 1
      } else if numBricksY <= numBricksZ {
        numBricksY += 1
      } else {
        numBricksZ += 1
      }
      totalBricks = numBricksX * numBricksY * numBricksZ
    }

    let width = numBricksX * brickSize
    let height = numBricksY * brickSize
    let depth = numBricksZ * brickSize
    let inCoreBrickCount = numBricksX * numBricksY * numBricksZ

    return (width, height, depth, inCoreBrickCount)
  }

  /**
   Calculates the integer cube root of a given integer.

   This method uses an iterative Newton-Raphson style approach to compute the cube root.
   Negative inputs are handled by taking the cube root of the absolute value and negating the result.

   - Parameter ni: The integer value.
   - Returns: The integer cube root of `ni`.
   */
  static func intCubeRoot(_ ni: Int) -> Int {
    if ni < 0 { return -intCubeRoot(-ni) }

    let n = Int64(ni)
    var x = n
    while x * x * x > n {
      x = (2 * x + n / (x * x)) / 3
    }
    return Int(x)
  }
}

/*
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of
 Duisburg-Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of
 this software and associated documentation files (the "Software"), to deal in the
 Software without restriction, including without limitation the rights to use, copy,
 modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and
 to permit persons to whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included in all copies
 or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
 CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR
 THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
