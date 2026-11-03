import Foundation
import Metal

/// Exclusive ownership transfers to the renderer after the worker has finished.
struct ScreenDatasetResources: @unchecked Sendable {
  let atlas: VolumeAtlas
  let hashTable: GPUHashtable
}

/// Data sources synchronize their own reads; TF copies belong only to this preparation.
struct ScreenDatasetPreparation: @unchecked Sendable {
  let dataset: BORGVRDatasetProtocol
  let device: MTLDevice
  let transferFunctions: [TransferFunction1D]
  let isoValue: Float
  let atlasSizeMB: Int
  let astcBlockSize: Int
  let initialBricks: Int
  let minimumHashTableSizeMB: Int
  let logger: LoggerBase?

  func prepare() async throws -> ScreenDatasetResources {
    let worker = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let atlas = try VolumeAtlas(device: device, maxMemory: atlasSizeMB * 1024 * 1024,
        borgData: dataset, transferFunctions: transferFunctions, isoValue: isoValue,
        astcBlockSize: astcBlockSize, logger: logger)
      try Task.checkCancellation()
      try? VolumeRenderResources.pageInInitialBricks(atlas: atlas, dataset: dataset,
        maximumCount: initialBricks)
      try Task.checkCancellation()
      let count = VolumeRenderResources.minimumHashTableElementCount(metadata: dataset.getMetadata(),
        representedMemoryMB: minimumHashTableSizeMB, minimumElementCount: 64)
      return ScreenDatasetResources(atlas: atlas,
        hashTable: GPUHashtable(minTableElementCount: count, device: device, logger: logger))
    }
    return try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: { worker.cancel() }
  }
}

