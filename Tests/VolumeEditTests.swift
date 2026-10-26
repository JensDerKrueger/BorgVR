import Foundation
import Compression
import Metal
import Darwin

func profileExistingEditState(directory: URL, dataset: URL) throws {
  let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-edit-opening-profile-\(UUID())")
  try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporary) }
  // APFS copy-on-write clones: the user's files are never opened for writing.
  for name in ["mask.checkpoint", "brush.journal", "bricks.cache"] {
    let source = directory.appendingPathComponent(name), target = temporary.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: source.path) else { continue }
    let result = source.path.withCString { source in target.path.withCString { clonefile(source, $0, 0) } }
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  }
  func measure<T>(_ label: String, _ operation: () throws -> T) rethrows -> T {
    let start = Date()
    let result = try operation()
    print(String(format: "%@: %.4fs", label, Date().timeIntervalSince(start)))
    fflush(stdout)
    return result
  }
  let source = try measure("Original dataset metadata/map") { try BORGVRFileData(filename: dataset.path) }
  let m = source.getMetadata()
  print("Dataset: \(m.width)x\(m.height)x\(m.depth), \(m.brickMetadata.count) bricks")
  if FileManager.default.fileExists(atPath: temporary.appendingPathComponent("mask.checkpoint").path) {
    let checkpoint = try measure("Read mask checkpoint") { try Data(contentsOf: temporary.appendingPathComponent("mask.checkpoint")) }
    print("Checkpoint bytes: \(checkpoint.count)")
    _ = try measure("Parse property-list container") { try PropertyListSerialization.propertyList(from: checkpoint, format: nil) }
    let journal = try measure("Decode/validate edit journal") {
      try BorgVRVolumeEditJournal(directory: temporary, datasetID: m.uniqueID,
        size: SIMD3(m.width, m.height, m.depth),
        spacing: SIMD3(Double(m.voxelSpacingX), Double(m.voxelSpacingY), Double(m.voxelSpacingZ)), componentCount: m.componentCount)
    }
    let snapshot = journal.snapshot()
    print("Revision \(snapshot.revision), tracked bricks \(snapshot.brickRevisions?.count ?? -1), pending regions \(snapshot.pending.count)")
    let nodes = measure("Flatten decoded mask") { snapshot.mask.computeNodes() }
    print("Mask nodes: \(nodes.count)")
    try measure("Close unchanged journal") { try journal.closeStorage() }
    let cache = try measure("Open brick cache") { try BorgVRVolumeEditBrickCache(url: temporary.appendingPathComponent("bricks.cache"), editStateID: snapshot.editStateID) }
    print("Used TOC: \(cache.openedUsingTableOfContents), recovered records: \(cache.recoveredRecordCount)")
    try cache.closeStorage()
  }
  let edited = try measure("Full edited data-source opening") { try BorgVREditableVolumeData(source: source, directory: temporary, logger: nil) }
  print("Pending bricks after opening: \(edited.editingStatus()?.pendingBrickCount ?? -1)")
  let buffer = source.allocateBrickBuffer()
  defer { buffer.deallocate() }
  let ids = Array(m.brickMetadata.indices)
  let residents = Set(ids.suffix(4096))
  edited.updateResidentBrickIDs(residents)
  try measure("Read all original bricks") {
    for id in ids { try source.getBrick(index: id, outputBuffer: buffer) }
  }
  try measure("Read all bricks through edited source") {
    for id in ids { try edited.getBrick(index: id, outputBuffer: buffer) }
  }
  try measure("Read resident original bricks") {
    for id in residents { try source.getBrick(index: id, outputBuffer: buffer) }
  }
  try measure("Read resident bricks through edited source") {
    for id in residents { try edited.getBrick(index: id, outputBuffer: buffer) }
  }
  var mask = try BorgVRVolumeEditMask(size: SIMD3(m.width, m.height, m.depth),
    spacing: SIMD3(Double(m.voxelSpacingX), Double(m.voxelSpacingY), Double(m.voxelSpacingZ)), componentCount: m.componentCount)
  var seed: UInt64 = 42
  let extent = SIMD3<Double>(mask.size) * mask.spacing
  func coordinate() -> Double {
    seed = seed &* 6364136223846793005 &+ 1
    return 0.2 + Double(seed >> 32) / Double(UInt32.max) * 0.6
  }
  for _ in 0..<24 {
    try mask.apply(.init(center: SIMD3(coordinate(), coordinate(), coordinate()) * extent,
      radius: max(extent.x, extent.y, extent.z) * 0.008), mode: .erase)
  }
  let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
  let encoded = try measure("Encode representative mask") { try encoder.encode(mask) }
  let decoded = try measure("Decode representative mask") { try PropertyListDecoder().decode(BorgVRVolumeEditMask.self, from: encoded) }
  let nodes = mask.computeNodes()
  print("Representative mask: \(nodes.count) nodes, \(encoded.count) bytes")
  try check(decoded.computeNodes() == nodes, "Mask profiling changed the edit geometry")
  let closed = DispatchSemaphore(value: 0)
  edited.shutdown { _ in closed.signal() }
  guard closed.wait(timeout: .now() + 30) == .success else { throw BorgVRVolumeEditError.invalidRevision }
}

private struct EditTestError: Error { let message: String }
private func check(_ condition: Bool, _ message: String) throws {
  if !condition { throw EditTestError(message: message) }
}

private final class UnavailableEditDataset: BORGVRDatasetProtocol {
  let base: BORGVRDatasetProtocol
  let onRead: (() -> Void)?
  init(_ base: BORGVRDatasetProtocol, onRead: (() -> Void)? = nil) { self.base = base; self.onRead = onRead }
  func getMetadata() -> BORGVRMetaData { base.getMetadata() }
  func allocateBrickBuffer() -> UnsafeMutablePointer<UInt8> { base.allocateBrickBuffer() }
  func newRequest() {}
  func getBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    onRead?()
    throw BORGVRDataError.brickNotYetAvailable(index: index)
  }
  func getFirstBrick(outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    onRead?()
    throw BORGVRDataError.brickNotYetAvailable(index: 0)
  }
}

/// An independent dense oracle, including odd-dimension subsampling and padding.
final class EditTestDataset: BORGVRDatasetProtocol {
  let metadata: BORGVRMetaData
  let bytesPerComponent: Int
  var levels: [[UInt32]]

  init(bytesPerComponent: Int) {
    self.bytesPerComponent = bytesPerComponent
    let scale: UInt32 = bytesPerComponent == 1 ? 1 : (bytesPerComponent == 2 ? 200 : 20_000_000)
    metadata = BORGVRMetaData(width: 7, height: 5, depth: 3, componentCount: 2,
      bytePerComponent: bytesPerComponent, voxelSpacingX: 0.25, voxelSpacingY: 0.5,
      voxelSpacingZ: 1, brickSize: 4, overlap: 1, minValue: 0, maxValue: Int(200 * scale),
      compression: false, datasetDescription: "Edit test", metaDescription: "")
    let voxelComponentCount = 210
    let rawValues: [UInt32] = (0..<voxelComponentCount).map { value in
      UInt32((value * 7 + 13) % 201) * scale
    }
    levels = [rawValues]
    rebuildLevels()
    for level in metadata.levelMetadata {
      for _ in 0..<(level.totalBricks.x * level.totalBricks.y * level.totalBricks.z) {
        metadata.append(offset: 0, size: 4 * 4 * 4 * 2 * bytesPerComponent,
                        minValue: 0, maxValue: Int(200 * scale))
      }
    }
  }

  func rebuildLevels() {
    levels = [levels[0]]
    for level in 1..<metadata.levelMetadata.count {
      let child = metadata.levelMetadata[level - 1].size
      let parent = metadata.levelMetadata[level].size
      var output: [UInt32] = []
      for z in 0..<parent.z {
        for y in 0..<parent.y {
          for x in 0..<parent.x {
            for c in 0..<2 {
              var sum: UInt64 = 0
              var count: UInt64 = 0
              for dz in 0..<2 {
                for dy in 0..<2 {
                  for dx in 0..<2 {
                    let px = x * 2 + dx, py = y * 2 + dy, pz = z * 2 + dz
                    if px < child.x && py < child.y && pz < child.z {
                      sum += UInt64(levels[level - 1][((pz * child.y + py) * child.x + px) * 2 + c])
                      count += 1
                    }
                  }
                }
              }
              output.append(UInt32(sum / count))
            }
          }
        }
      }
      levels.append(output)
    }
  }

  func bytes(index: Int, border: BorgVRVolumeEditBorderMode) -> [UInt8] {
    let l = metadata.levelMetadata.lastIndex { $0.prevBricks <= index }!
    let layout = metadata.levelMetadata[l]
    let local = index - layout.prevBricks
    let bx = local % layout.totalBricks.x
    let by = (local / layout.totalBricks.x) % layout.totalBricks.y
    let bz = local / (layout.totalBricks.x * layout.totalBricks.y)
    var result: [UInt8] = []
    for z in 0..<4 {
      for y in 0..<4 {
        for x in 0..<4 {
          var p = [bx * 2 + x - 1, by * 2 + y - 1, bz * 2 + z - 1]
          let size = [layout.size.x, layout.size.y, layout.size.z]
          var outside = false
          for axis in 0..<3 where p[axis] < 0 || p[axis] >= size[axis] {
            switch border {
              case .zero: outside = true
              case .clamp: p[axis] = min(max(p[axis], 0), size[axis] - 1)
              case .repeatValue: p[axis] = (p[axis] % size[axis] + size[axis]) % size[axis]
            }
          }
          for c in 0..<2 {
            let value: UInt32 = outside ? 0 : levels[l][((p[2] * size[1] + p[1]) * size[0] + p[0]) * 2 + c]
            for byte in 0..<bytesPerComponent { result.append(UInt8(truncatingIfNeeded: value >> (byte * 8))) }
          }
        }
      }
    }
    return result
  }

  func newRequest() {}
  func getMetadata() -> BORGVRMetaData { metadata }
  func getBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    let data = bytes(index: index, border: .clamp)
    _ = data.withUnsafeBytes { memcpy(outputBuffer, $0.baseAddress!, data.count) }
  }
  func getFirstBrick(outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    try getBrick(index: metadata.brickMetadata.count - 1, outputBuffer: outputBuffer)
  }
  func allocateBrickBuffer() -> UnsafeMutablePointer<UInt8> {
    .allocate(capacity: 4 * 4 * 4 * 2 * bytesPerComponent)
  }
}

func runVolumeEditTests() throws {
  try testCompactEditMask()
  try testChannelEditMask()
  try testChannelEditMaterialization()
  try testWideChannelEditMaterialization()
  try testChannelEditPersistence()
  try testSourceCacheResidentEviction()
  let size = SIMD3<Int>(7, 5, 3)
  let spacing = SIMD3<Double>(0.25, 0.5, 1)
  let sphere = BorgVRVolumeBrushSample(center: SIMD3(0.9, 1.2, 1.4), radius: 0.85)
  let restore = BorgVRVolumeBrushSample(center: SIMD3(1.1, 1.2, 1.4), radius: 0.5)
  for width in [1, 2, 4] {
    let source = EditTestDataset(bytesPerComponent: width)
    let oracle = EditTestDataset(bytesPerComponent: width)
    var mask = try BorgVRVolumeEditMask(size: size, spacing: spacing, componentCount: 2)
    let emptySnapshot = mask
    try mask.apply(sphere, mode: .erase)
    try mask.apply(restore, mode: .restore)
    for z in 0..<3 {
      for y in 0..<5 {
        for x in 0..<7 {
          let p = SIMD3<Double>(Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5) * spacing
          func inside(_ s: BorgVRVolumeBrushSample) -> Bool {
            let d = p - s.center
            return d.x * d.x + d.y * d.y + d.z * d.z <= s.radius * s.radius
          }
          if inside(sphere) && !inside(restore) {
            oracle.levels[0][((z * 5 + y) * 7 + x) * 2] = 0
            oracle.levels[0][((z * 5 + y) * 7 + x) * 2 + 1] = 0
          }
        }
      }
    }
    oracle.rebuildLevels()
    try check(emptySnapshot.isOriginal, "Editing changed an immutable snapshot")
    for border in [BorgVRVolumeEditBorderMode.zero, .clamp, .repeatValue] {
      let executor = try BorgVRCPUVolumeEditExecutor(source: source, border: border)
      for index in source.metadata.brickMetadata.indices {
        let result = try executor.materialize(index: index, mask: mask, revision: 2)
        let expected = oracle.bytes(index: index, border: border)
        try check(result.bytes == expected, "Brick/halo/LOD mismatch: width \(width), brick \(index), \(border)")
        for c in 0..<2 {
          var values: [Int] = []
          for v in 0..<64 {
            let offset = (v * 2 + c) * width
            let value = (0..<width).reduce(UInt64(0)) { $0 | UInt64(expected[offset + $1]) << ($1 * 8) }
            values.append(Int(value))
          }
          try check(result.componentRanges[c] == BORGVRComponentRange(minValue: values.min()!, maxValue: values.max()!),
                    "Incorrect component range")
        }
      }
      var cancellationChecks = 0
      do {
        _ = try executor.materialize(index: source.metadata.brickMetadata.count - 1, mask: mask, revision: 2) {
          cancellationChecks += 1
          return cancellationChecks >= 3
        }
        throw EditTestError(message: "CPU brick calculation ignored cancellation")
      } catch is CancellationError {}
    }
    try mask.apply(sphere, mode: .restore)
    try check(mask.isOriginal, "Restore did not collapse the sparse tree")
    let result = try BorgVRCPUVolumeEditExecutor(source: source, border: .clamp)
      .materialize(index: 0, mask: mask, revision: 3)
    try check(result.matchesOriginal, "Full restore retained an override")
  }
  try testEditJournal(size: size, spacing: spacing, sphere: sphere)
  try testTransientEditSnapshot(size: size, spacing: spacing, sphere: sphere)
  try testBottomUpEditMaterialization()
  try testMaterializerCacheCompletion()
  try testEditedBrickCacheRecovery()
  try testFailedEditActivationPreservesPreviousState()
  try testTransientEditPersistenceRecovery()
  try testEditedHierarchyRecoveryIsIdempotent()
  try testEditedBrickRecoveryCancellation()
  if ProcessInfo.processInfo.environment["BORGVR_EDIT_BENCHMARK"] == "1" {
    try benchmarkEditMaterialization()
    try benchmarkEditCacheOpening()
  }
  try testEditCache()
  try testEditCacheTableOfContents()
  try testEditableDataset()
  try testResidentEditsStayReadyDuringHierarchyWork()
  try testResidentRemoteBrickCanBeEditedOffline()
  try testGPUBrushHistoryDoesNotWaitForCPUBricks()
  try testReopenReusesOnlyAffectedBrickVersions()
  try testAdjacentEditStorage()
  try testDiscardAllEditsDuringBackgroundWork()
  try testNewlyVisibleBrickBypassesHiddenEditWork()
  try testPendingEraseVisibilityBounds()
  try testRestoreSkipsUneditedBricks()
  try testBrickUpdateActivity()
  try testCancelledEditExport()
  try testRawEditExport()
  try testPendingCompressedEditExport()
  try testLargeRawExport()
  try testOfflineCachedExport()
  var largeMask = try BorgVRVolumeEditMask(size: SIMD3(repeating: 2048), spacing: SIMD3(repeating: 1.0 / 2048))
  let fullSphere = BorgVRVolumeBrushSample(center: SIMD3(repeating: 0.5), radius: 1)
  try largeMask.apply(fullSphere, mode: .erase)
  if case .erased = largeMask.root {} else { throw EditTestError(message: "Full erase did not collapse to one node") }
  try largeMask.apply(fullSphere, mode: .restore)
  try check(largeMask.isOriginal, "Full restore of 2k^3 volume failed")
  let source = EditTestDataset(bytesPerComponent: 2)
  let unavailable = UnavailableEditDataset(source)
  let executor = try BorgVRCPUVolumeEditExecutor(source: unavailable, border: .clamp)
  var offlineMask = try BorgVRVolumeEditMask(size: size, spacing: spacing, componentCount: 2)
  try offlineMask.apply(BorgVRVolumeBrushSample(center: .zero, radius: 100), mode: .erase)
  for index in source.metadata.brickMetadata.indices {
    let result = try executor.materialize(index: index, mask: offlineMask, revision: 1)
    try check(result.bytes.allSatisfy { $0 == 0 }, "Fully erased remote brick required source bytes")
  }
  try offlineMask.apply(BorgVRVolumeBrushSample(center: .zero, radius: 100), mode: .restore)
  do {
    _ = try executor.materialize(index: 0, mask: offlineMask, revision: 2)
    throw EditTestError(message: "Restore fabricated missing source data")
  } catch BORGVRDataError.brickNotYetAvailable {}
  print("Volume edit CPU tests passed")
}

private func testChannelEditMask() throws {
  let full = BorgVRVolumeBrushSample(center: SIMD3(repeating: 0.5), radius: 100)
  let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
  for count in [1, 2, 32, 33, 65, BORGVRMetaData.maximumComponentCount] {
    var mask = try BorgVRVolumeEditMask(size: SIMD3(7, 5, 3), spacing: SIMD3(repeating: 1), componentCount: count)
    let selected = BorgVRVolumeEditChannels.selected([count - 1])
    try mask.apply(full, mode: .erase, channels: selected)
    try check(mask.isErased(at: .zero, component: count - 1), "Selected channel was not erased")
    try check(count == 1 || !mask.isErased(at: .zero, component: 0), "Erase changed an unselected channel")
    try check(mask.coverage(in: mask.bounds, channels: selected) == .erased, "Channel coverage lost a full erase")
    if count > 1 {
      try check(mask.coverage(in: mask.bounds) == .mixed, "Partial channels incorrectly became a fully erased brick")
      try check(mask.coverage(in: mask.bounds, channels: .selected([0])) == .original,
        "Restore cannot skip an untouched channel")
    }
    let data = try encoder.encode(mask)
    let decoded = try PropertyListDecoder().decode(BorgVRVolumeEditMask.self, from: data)
    try check(decoded.componentCount == count && decoded.computeNodes() == mask.computeNodes(),
      "Channel mask did not round-trip")
    try mask.apply(full, mode: .erase)
    try check(mask.computeNodes() == [SIMD2(1, 0)], "Full erase lost its single-node fast path")
    try mask.apply(full, mode: .restore, channels: selected)
    try check(!mask.isErased(at: .zero, component: count - 1), "Selected restore did not restore its channel")
    try check(count == 1 || mask.isErased(at: .zero, component: 0), "Restore resurrected another channel")
    try mask.apply(full, mode: .restore)
    try check(mask.isOriginal && mask.computeNodes() == [SIMD2(0, 0)], "Full restore did not collapse the tree")
  }
  var single = try BorgVRVolumeEditMask(size: SIMD3(7, 5, 3), spacing: SIMD3(repeating: 1))
  var explicit = single
  let brush = BorgVRVolumeBrushSample(center: SIMD3(2, 2, 1), radius: 1.3)
  try single.apply(brush, mode: .erase)
  try explicit.apply(brush, mode: .erase, channels: .selected([0]))
  try check(single.computeNodes() == explicit.computeNodes(), "Single-channel edits changed the compact tree layout")
  let container = try PropertyListSerialization.propertyList(from: encoder.encode(explicit), format: nil) as! [String: Any]
  let nodes = container["nodes"] as! Data
  try check(nodes.allSatisfy { $0 <= 2 }, "Single-channel mask contains per-channel payloads")
  for selection in [BorgVRVolumeEditChannels.selected([]), .selected([-1]), .selected([1]), .selected([0, 0])] {
    do {
      try single.apply(full, mode: .erase, channels: selection)
      throw EditTestError(message: "Invalid channel selection accepted")
    } catch BorgVRVolumeEditError.invalidBrush {}
  }
}

private func testChannelEditMaterialization() throws {
  for width in [1, 2, 4] {
    let source = EditTestDataset(bytesPerComponent: width), oracle = EditTestDataset(bytesPerComponent: width)
    let m = source.metadata
    var mask = try BorgVRVolumeEditMask(size: SIMD3(m.width, m.height, m.depth),
      spacing: SIMD3(0.25, 0.5, 1), componentCount: 2)
    let operations: [(BorgVRVolumeBrushMode, BorgVRVolumeEditChannels, BorgVRVolumeBrushSample)] = [
      (.erase, .selected([0]), .init(center: SIMD3(0.9, 1.2, 1.4), radius: 0.85)),
      (.erase, .selected([1]), .init(center: SIMD3(1.1, 1.1, 1.3), radius: 0.65)),
      (.restore, .selected([0]), .init(center: SIMD3(1.1, 1.2, 1.4), radius: 0.5)),
      (.erase, .all, .init(center: .zero, radius: 100)),
      (.restore, .selected([1]), .init(center: .zero, radius: 100)),
      (.restore, .all, .init(center: .zero, radius: 100))
    ]
    for (step, operation) in operations.enumerated() {
      let (mode, channels, sample) = operation
      try mask.apply(sample, mode: mode, channels: channels)
      for z in 0..<m.depth { for y in 0..<m.height { for x in 0..<m.width {
        let point = (SIMD3<Double>(SIMD3(x, y, z)) + SIMD3<Double>(repeating: 0.5)) * mask.spacing
        let delta = point - sample.center
        guard delta.x * delta.x + delta.y * delta.y + delta.z * delta.z <= sample.radius * sample.radius else { continue }
        for c in 0..<2 where channels.contains(c) {
          let offset = ((z * m.height + y) * m.width + x) * 2 + c
          oracle.levels[0][offset] = mode == .erase ? 0 : source.levels[0][offset]
        }
      } } }
      oracle.rebuildLevels()
      let reference = try BorgVRCPUVolumeEditExecutor(source: source, border: .clamp)
      for gpu in [false, true] {
        let builder = try BorgVRVolumeEditMaterializer(source: source, usesMetal: gpu)
        for id in m.brickMetadata.indices.reversed() {
          let expected = oracle.bytes(index: id, border: .clamp)
          let actual = try builder.materialize(index: id, mask: mask, revision: UInt64(step + 1), revisions: nil,
            useGPU: gpu, cached: { _, _ in nil }, store: { _ in }, isCancelled: { false })
          let cpu = try reference.materialize(index: id, mask: mask, revision: UInt64(step + 1))
          try check(actual.bytes == expected && cpu.bytes == expected,
            "Channel edit differs from dense oracle: width \(width), step \(step), brick \(id), GPU \(gpu)")
          try check(actual.componentRanges == cpu.componentRanges, "Per-channel min/max differ")
        }
        if gpu, step < 3, MTLCreateSystemDefaultDevice() != nil {
          try check(builder.metalBrickCount > 0, "Partial-channel GPU rebuild fell back to CPU")
        }
      }
    }
  }
}

private func testChannelEditPersistence() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-channel-edits-\(UUID())")
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = EditTestDataset(bytesPerComponent: 2), m = source.metadata
  let edited = try BorgVREditableVolumeData(source: source, directory: directory, logger: nil)
  let full = BorgVRVolumeBrushSample(center: .zero, radius: 100)
  try waitForEditOperation { edited.brush([full], mode: .erase, channels: .selected([0]), completion: $0) }
  let revision = edited.journal.snapshot().revision
  try waitForEditOperation { edited.brush([full], mode: .restore, channels: .selected([1]), completion: $0) }
  try check(edited.journal.snapshot().revision == revision, "Restore of an untouched channel enqueued brick work")
  try waitForEditOperation { edited.shutdown(completion: $0) }
  let reopened = try BorgVREditableVolumeData(source: source, directory: directory, logger: nil)
  try waitForEditOperation {
    reopened.preparePendingEdits(cancellationToken: .init(), progress: { _ in }, completion: $0)
  }
  let snapshot = reopened.journal.snapshot()
  try check(snapshot.mask.componentCount == 2 && snapshot.mask.isErased(at: .zero, component: 0) &&
    !snapshot.mask.isErased(at: .zero, component: 1), "Reopening lost the channel mask")
  let output = source.allocateBrickBuffer()
  defer { output.deallocate() }
  let oracle = EditTestDataset(bytesPerComponent: 2)
  for i in stride(from: 0, to: oracle.levels[0].count, by: 2) { oracle.levels[0][i] = 0 }
  oracle.rebuildLevels()
  for id in m.brickMetadata.indices {
    try reopened.getBrick(index: id, outputBuffer: output)
    let expected = oracle.bytes(index: id, border: .clamp)
    try check(Array(UnsafeBufferPointer(start: output, count: expected.count)) == expected,
      "Cached multichannel brick changed after reopening")
  }
  try waitForEditOperation { reopened.brush([full], mode: .restore, channels: .selected([0]), completion: $0) }
  try check(reopened.journal.snapshot().mask.isOriginal, "Final channel restore did not release the mask")
  try waitForEditOperation { reopened.shutdown(completion: $0) }
}

private final class WideChannelEditDataset: BORGVRDatasetProtocol {
  let metadata = BORGVRMetaData(width: 1, height: 1, depth: 1, componentCount: 65, bytePerComponent: 2,
    voxelSpacingX: 1, voxelSpacingY: 1, voxelSpacingZ: 1, brickSize: 4, overlap: 1,
    minValue: 0, maxValue: 65, compression: false, datasetDescription: "Wide channels", metaDescription: "")
  let bytes: [UInt8] = (0..<(64 * 65)).flatMap { [UInt8($0 % 65 + 1), UInt8(0)] }
  init() { metadata.append(offset: 0, size: bytes.count, minValue: 1, maxValue: 65) }
  func getMetadata() -> BORGVRMetaData { metadata }
  func newRequest() {}
  func allocateBrickBuffer() -> UnsafeMutablePointer<UInt8> { .allocate(capacity: bytes.count) }
  func getBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    bytes.withUnsafeBytes { _ = memcpy(outputBuffer, $0.baseAddress!, bytes.count) }
  }
  func getFirstBrick(outputBuffer: UnsafeMutablePointer<UInt8>) throws { try getBrick(index: 0, outputBuffer: outputBuffer) }
}

private func testWideChannelEditMaterialization() throws {
  let source = WideChannelEditDataset()
  var mask = try BorgVRVolumeEditMask(size: SIMD3(repeating: 1), spacing: SIMD3(repeating: 1), componentCount: 65)
  try mask.apply(.init(center: SIMD3(repeating: 0.5), radius: 1), mode: .erase, channels: .selected([0, 31, 32, 64]))
  var expected = source.bytes
  for voxel in 0..<64 { for channel in [0, 31, 32, 64] { expected[(voxel * 65 + channel) * 2] = 0 } }
  for gpu in [false, true] {
    let builder = try BorgVRVolumeEditMaterializer(source: source, usesMetal: gpu)
    let actual = try builder.materialize(index: 0, mask: mask, revision: 1, revisions: nil,
      useGPU: gpu, cached: { _, _ in nil }, store: { _ in }, isCancelled: { false })
    try check(actual.bytes == expected, "Channel bits beyond 32/64 failed in CPU/Metal rebuilding")
    if gpu, MTLCreateSystemDefaultDevice() != nil {
      try check(builder.metalBrickCount == 1, "Wide-channel GPU test did not run on Metal")
    }
  }
}

private func testFailedEditActivationPreservesPreviousState() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-activation-recovery-\(UUID())")
  defer { try? FileManager.default.removeItem(at: root) }
  let base = EditTestDataset(bytesPerComponent: 2)
  let catalog = try BorgVRVolumeEditCatalog(root: root, datasetID: base.metadata.uniqueID)
  let source = BorgVRVolumeEditDataSource(original: base, catalog: catalog, logger: nil, backgroundWorkChanged: { _ in })
  defer { try? waitForEditOperation { source.shutdown(completion: $0) } }
  func state() -> BorgVRVolumeEditState {
    .init(id: UUID(), datasetID: base.metadata.uniqueID, name: "Test", kind: .local, createdAt: Date(), modifiedAt: Date())
  }
  let previous = state()
  try waitForEditOperation { source.activate(previous, completion: $0) }
  let brush = BorgVRVolumeBrushSample(center: .zero, radius: 100)
  try waitForEditOperation { source.brush([brush], mode: .erase, completion: $0) }
  let mask = try BorgVRVolumeEditMask(size: SIMD3(7, 5, 3), spacing: SIMD3(0.25, 0.5, 1))
  let invalid = BorgVRVolumeEditSnapshot(datasetID: UUID().uuidString, stateID: UUID(), revision: 0, mask: mask)
  do {
    try waitForEditOperation { source.activate(state(), snapshot: invalid, completion: $0) }
    throw EditTestError(message: "Invalid state switch succeeded")
  } catch BorgVRVolumeEditError.incompatibleDataset {}
  try check(source.editingStatus() != nil, "Failed switch destroyed the previous source")
  try waitForEditOperation { source.brush([brush], mode: .restore, completion: $0) }
}

private func testTransientEditPersistenceRecovery() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-persistence-recovery-\(UUID())")
  defer { try? FileManager.default.removeItem(at: root) }
  let base = EditTestDataset(bytesPerComponent: 2)
  let source = try BorgVREditableVolumeData(source: base, directory: root, logger: nil)
  defer { try? waitForEditOperation { source.shutdown(completion: $0) } }
  let cacheURL = root.appendingPathComponent("bricks.cache")
  try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
  try waitForEditOperation { source.brush([.init(center: .zero, radius: 100)], mode: .erase, completion: $0) }
  do {
    try prepareEdits(source)
    throw EditTestError(message: "Unwritable cache reported success")
  } catch is EditTestError { throw EditTestError(message: "Unwritable cache reported success") }
  catch {}
  let revision = source.contentRevision
  try FileManager.default.removeItem(at: cacheURL)
  try prepareEdits(source)
  try check(source.contentRevision == revision, "Persistence retry unnecessarily invalidated the renderer")
  try waitForEditOperation { source.shutdown(completion: $0) }
  let reopened = try BorgVREditableVolumeData(source: base, directory: root, logger: nil,
    executor: UnexpectedEditExecutor())
  defer { try? waitForEditOperation { reopened.shutdown(completion: $0) } }
  let buffer = base.allocateBrickBuffer()
  defer { buffer.deallocate() }
  for id in base.metadata.brickMetadata.indices { try reopened.getBrick(index: id, outputBuffer: buffer) }
}

private final class EditExportResult: @unchecked Sendable {
  let lock = NSLock()
  var result: Result<URL, Error>?
  var progress: [Double] = []
}

private final class UnexpectedEditExecutor: BorgVRVolumeEditExecutor {
  func materialize(index: Int, mask: BorgVRVolumeEditMask, revision: UInt64,
                   isCancelled: @escaping () -> Bool) throws -> BorgVRMaterializedEditBrick {
    throw EditTestError(message: "Reopening unnecessarily rebuilt brick \(index) at revision \(revision)")
  }
}

private final class DiscardEditResult: @unchecked Sendable {
  let lock = NSLock()
  var error: Error?
}

private func waitForEditOperation(_ start: (@escaping @Sendable (Error?) -> Void) -> Void) throws {
  let done = DispatchSemaphore(value: 0), result = DiscardEditResult()
  start { error in result.lock.withLock { result.error = error }; done.signal() }
  try check(done.wait(timeout: .now() + 30) == .success, "Edit operation timed out")
  if let error = result.lock.withLock({ result.error }) { throw error }
}

private func prepareEdits(_ dataset: BorgVREditableVolumeData) throws {
  try waitForEditOperation { dataset.preparePendingEdits(cancellationToken: .init(), progress: { _ in }, completion: $0) }
}

private func testMaterializerCacheCompletion() throws {
  let source = EditTestDataset(bytesPerComponent: 1), m = source.metadata
  let builder = try BorgVRVolumeEditMaterializer(source: source, usesMetal: false)
  var mask = try BorgVRVolumeEditMask(size: SIMD3(m.width, m.height, m.depth),
    spacing: SIMD3(Double(m.voxelSpacingX), Double(m.voxelSpacingY), Double(m.voxelSpacingZ)), componentCount: m.componentCount)
  try mask.apply(.init(center: .zero, radius: 100), mode: .erase)
  var completions = 0
  func read(_ cached: @escaping BorgVRVolumeEditMaterializer.Lookup,
            store: @escaping (BorgVRMaterializedEditBrick) throws -> Void,
            cancelled: @escaping () -> Bool = { false }) throws -> BorgVRMaterializedEditBrick {
    try builder.materialize(index: 0, mask: mask, revision: 1, revisions: nil, useGPU: false,
      cached: cached, store: store, isCancelled: cancelled)
  }
  let first = try read({ _, _ in nil }, store: { _ in completions += 1 })
  _ = try read({ _, _ in nil }, store: { _ in
    completions += 1
    // A cache completion must run outside the materializer's condition lock.
    _ = try builder.materialize(index: 1, mask: mask, revision: 1, isCancelled: { false })
  })
  _ = try read({ _, _ in first }, store: { _ in completions += 1 })
  try check(completions == 3, "Computed, RAM-cached and externally cached bricks did not share completion")
  for external in [false, true] {
    var cancelled = false
    do {
      _ = try read({ _, _ in cancelled = true; return external ? first : nil },
        store: { _ in completions += 1 }, cancelled: { cancelled })
      throw EditTestError(message: "Cancelled cached result was published")
    } catch is CancellationError {}
    do {
      _ = try read({ _, _ in external ? first : nil }, store: { _ in throw BorgVRVolumeEditError.invalidRevision })
      throw EditTestError(message: "Cached result ignored completion failure")
    } catch BorgVRVolumeEditError.invalidRevision {}
  }
  try check(completions == 3, "Cancellation still invoked cache completion")
}

private final class RecoveryUniformDataset: BORGVRDatasetProtocol {
  let metadata = BORGVRMetaData(width: 8320, height: 64, depth: 64, componentCount: 1,
    bytePerComponent: 1, voxelSpacingX: 1, voxelSpacingY: 1, voxelSpacingZ: 1,
    brickSize: 64, overlap: 0, minValue: 200, maxValue: 200, compression: false,
    datasetDescription: "Cache recovery fixture", metaDescription: "")
  init() {
    for level in metadata.levelMetadata {
      for _ in 0..<(level.totalBricks.x * level.totalBricks.y * level.totalBricks.z) {
        metadata.append(offset: 8, size: 64 * 64 * 64, minValue: 200, maxValue: 200)
      }
    }
  }
  func getMetadata() -> BORGVRMetaData { metadata }
  func allocateBrickBuffer() -> UnsafeMutablePointer<UInt8> { .allocate(capacity: 64 * 64 * 64) }
  func newRequest() {}
  func getBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws { memset(outputBuffer, 200, 64 * 64 * 64) }
  func getFirstBrick(outputBuffer: UnsafeMutablePointer<UInt8>) throws { try getBrick(index: 0, outputBuffer: outputBuffer) }
}

// Inspect only temporary cache files, then damage one live payload without touching its TOC or neighbors.
private func editCachePayloads(_ url: URL, index: Int) throws -> [Range<Int>] {
  let data = try Data(contentsOf: url)
  func integer(_ offset: Int) -> Int {
    data.withUnsafeBytes { Int(UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self))) }
  }
  var offset = 25, result: [Range<Int>] = []
  while offset + 96 <= data.count, data.subdata(in: offset..<(offset + 8)) == Data("BVBRK02\n".utf8) {
    let length = integer(offset + 8), id = integer(offset + 16)
    try check(length >= 96 && length <= data.count - offset, "Invalid recovery fixture record")
    if id == index { result.append((offset + 96 + integer(offset + 56) * 16)..<(offset + length)) }
    offset += length
  }
  return result
}

private func damageEditCache(_ url: URL, index: Int) throws {
  let payload = try editCachePayloads(url, index: index).last
  try check(payload?.isEmpty == false, "Recovery fixture has no live payload")
  let file = try FileHandle(forUpdating: url)
  defer { try? file.close() }
  try file.seek(toOffset: UInt64(payload!.lowerBound))
  let byte = try file.read(upToCount: 1)![0]
  try file.seek(toOffset: UInt64(payload!.lowerBound))
  try file.write(contentsOf: Data([byte ^ 0xFF]))
  try file.synchronize()
}

private func readRecoveredBrick(_ dataset: BorgVREditableVolumeData, index: Int,
                                buffer: UnsafeMutablePointer<UInt8>) throws {
  let deadline = Date().addingTimeInterval(10)
  while true {
    do { try dataset.getBrick(index: index, outputBuffer: buffer); return }
    catch BORGVRDataError.brickNotYetAvailable where Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
  }
}

private func testEditedBrickCacheRecovery() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-cache-recovery-\(UUID())")
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = RecoveryUniformDataset(), m = source.metadata
  let journal = try BorgVRVolumeEditJournal(directory: directory, datasetID: m.uniqueID,
    size: SIMD3(m.width, m.height, m.depth), spacing: SIMD3(repeating: 1))
  try journal.append(.init(id: UUID(), revision: 1, mode: .erase,
    samples: [.init(center: SIMD3(4160, 32, 32), radius: 10000)], affectedBrickIDs: Array(m.brickMetadata.indices)))
  try journal.closeStorage()
  var dataset = try BorgVREditableVolumeData(source: source, directory: directory, logger: nil)
  defer { try? waitForEditOperation { dataset.shutdown(completion: $0) } }
  try prepareEdits(dataset)
  let cacheURL = directory.appendingPathComponent("bricks.cache")
  let buffer = source.allocateBrickBuffer()
  defer { buffer.deallocate() }
  // 265 decoded bricks exceed the 32 MiB ready cache. Brick 50 remains in
  // the materializer's 64 MiB memo cache after sequential foreground preparation.
  for reopen in [false, true] {
    if reopen {
      try waitForEditOperation { dataset.shutdown(completion: $0) }
      dataset = try BorgVREditableVolumeData(source: source, directory: directory, logger: nil)
    }
    let revision = dataset.contentRevision
    let records = try editCachePayloads(cacheURL, index: 50).count
    let neighbor = try editCachePayloads(cacheURL, index: 51).last!
    let neighborBytes = try Data(contentsOf: cacheURL).subdata(in: neighbor)
    try damageEditCache(cacheURL, index: 50)
    do {
      try dataset.getBrick(index: 50, outputBuffer: buffer)
      throw EditTestError(message: "Recovery fixture was still in the ready cache")
    } catch BORGVRDataError.brickNotYetAvailable {}
    try readRecoveredBrick(dataset, index: 50, buffer: buffer)
    try check((0..<(64 * 64 * 64)).allSatisfy { buffer[$0] == 0 }, "Recovery changed edited voxels")
    try prepareEdits(dataset)
    try check(dataset.contentRevision == revision + 1 && dataset.changedBrickIDs(since: revision) == [50],
      "Recovery did not publish exactly the damaged brick once")
    try check(dataset.editingStatus()?.pendingBrickCount == 0, "Recovery left the brick dirty")
    try check(try editCachePayloads(cacheURL, index: 50).count == records + 1, "Recovery did not persist a replacement")
    try check(try Data(contentsOf: cacheURL).subdata(in: neighbor) == neighborBytes, "Recovery rewrote a healthy neighbor")
    let stable = try Data(contentsOf: cacheURL)
    for _ in 0..<20 { try dataset.getBrick(index: 50, outputBuffer: buffer) }
    try prepareEdits(dataset)
    try check(dataset.contentRevision == revision + 1 && Data(contentsOf: cacheURL) == stable,
      "Clean cache hits caused duplicate publications or disk writes")
  }
  try waitForEditOperation { dataset.shutdown(completion: $0) }
  dataset = try BorgVREditableVolumeData(source: source, directory: directory, logger: nil,
    executor: UnexpectedEditExecutor())
  for id in m.brickMetadata.indices { try dataset.getBrick(index: id, outputBuffer: buffer) }
}

private final class PausingRecoveryDataset: BORGVRDatasetProtocol {
  let base = EditTestDataset(bytesPerComponent: 2)
  let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var armed = false
  func arm() { lock.withLock { armed = true } }
  func getMetadata() -> BORGVRMetaData { base.metadata }
  func allocateBrickBuffer() -> UnsafeMutablePointer<UInt8> { base.allocateBrickBuffer() }
  func newRequest() {}
  func getBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    let pause = lock.withLock { let pause = armed; armed = false; return pause }
    if pause {
      entered.signal()
      try check(resume.wait(timeout: .now() + 10) == .success, "Recovery source was not released")
    }
    try base.getBrick(index: index, outputBuffer: outputBuffer)
  }
  func getFirstBrick(outputBuffer: UnsafeMutablePointer<UInt8>) throws { try getBrick(index: base.metadata.brickMetadata.count - 1, outputBuffer: outputBuffer) }
}

private func testEditedHierarchyRecoveryIsIdempotent() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-hierarchy-recovery-\(UUID())")
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = EditTestDataset(bytesPerComponent: 2)
  var dataset = try BorgVREditableVolumeData(source: source, directory: directory, logger: nil)
  defer { try? waitForEditOperation { dataset.shutdown(completion: $0) } }
  try waitForEditOperation {
    dataset.brush([.init(center: SIMD3(0.375, 0.75, 1.5), radius: 0.1)], mode: .erase, completion: $0)
  }
  try prepareEdits(dataset)
  try waitForEditOperation { dataset.shutdown(completion: $0) }
  dataset = try BorgVREditableVolumeData(source: source, directory: directory, logger: nil)
  let cacheURL = directory.appendingPathComponent("bricks.cache")
  let ids = source.metadata.brickMetadata.indices
  let parent = ids.last!, revision = dataset.contentRevision
  let counts = try ids.map { try editCachePayloads(cacheURL, index: $0).count }
  try damageEditCache(cacheURL, index: parent)
  let buffer = dataset.allocateBrickBuffer()
  defer { buffer.deallocate() }
  try readRecoveredBrick(dataset, index: parent, buffer: buffer)
  try prepareEdits(dataset)
  let after = try ids.map { try editCachePayloads(cacheURL, index: $0).count }
  try check(zip(ids, zip(counts, after)).allSatisfy { id, count in count.1 == count.0 + (id == parent ? 1 : 0) },
    "Hierarchy repair rewrote healthy child bricks")
  try check(dataset.contentRevision == revision + 1 && dataset.changedBrickIDs(since: revision) == [parent],
    "Hierarchy repair republished healthy children")
}

private func testEditedBrickRecoveryCancellation() throws {
  for action in ["edit", "discard", "close"] {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-recovery-\(action)-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = PausingRecoveryDataset()
    var dataset = try BorgVREditableVolumeData(source: source, directory: directory, logger: nil)
    defer { source.resume.signal(); try? waitForEditOperation { dataset.shutdown(completion: $0) } }
    try waitForEditOperation {
      dataset.brush([.init(center: SIMD3(0.375, 0.75, 1.5), radius: 0.1)], mode: .erase, completion: $0)
    }
    try prepareEdits(dataset)
    try waitForEditOperation { dataset.shutdown(completion: $0) }
    dataset = try BorgVREditableVolumeData(source: source, directory: directory, logger: nil)
    let cacheURL = directory.appendingPathComponent("bricks.cache")
    try damageEditCache(cacheURL, index: 0)
    let records = try editCachePayloads(cacheURL, index: 0).count
    source.arm()
    let buffer = dataset.allocateBrickBuffer()
    defer { buffer.deallocate() }
    do { try dataset.getBrick(index: 0, outputBuffer: buffer) }
    catch BORGVRDataError.brickNotYetAvailable {}
    try check(source.entered.wait(timeout: .now() + 5) == .success, "Recovery did not rebuild from original + mask")
    if action == "edit" {
      try waitForEditOperation { dataset.brush([.init(center: .zero, radius: 100)], mode: .restore, completion: $0) }
      source.resume.signal()
      try prepareEdits(dataset)
      try readRecoveredBrick(dataset, index: 0, buffer: buffer)
      try check(Array(UnsafeBufferPointer(start: buffer, count: 256)) == source.base.bytes(index: 0, border: .clamp),
        "Old recovery overwrote a newer restore")
      try check(try editCachePayloads(cacheURL, index: 0).count == records + 1,
        "Recovery persisted an obsolete revision before the current restore")
    } else {
      let done = DispatchSemaphore(value: 0), result = DiscardEditResult()
      let completed: @Sendable (Error?) -> Void = { error in result.lock.withLock { result.error = error }; done.signal() }
      if action == "discard" { dataset.discardAllEdits(completion: completed) }
      else { dataset.shutdown(completion: completed) }
      source.resume.signal()
      try check(done.wait(timeout: .now() + 10) == .success, "Recovery blocked discard/close")
      if let error = result.lock.withLock({ result.error }) { throw error }
      if action == "discard" {
        try check(!FileManager.default.fileExists(atPath: directory.path), "Recovery recreated discarded sidecars")
      } else {
        try check(try editCachePayloads(cacheURL, index: 0).count == records, "Recovery persisted a brick after close")
      }
    }
  }
}

private func testAdjacentEditStorage() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-edit-storage-\(UUID())")
  defer { try? FileManager.default.removeItem(at: root) }
  let id = UUID().uuidString
  let support = root.appendingPathComponent("Support")
  let dataURL = root.appendingPathComponent("Datasets/test.data")
  let builtin = try BorgVRVolumeEditStorage.directory(datasetURL: nil, datasetID: id, applicationSupportURL: support)
  let adjacent = try BorgVRVolumeEditStorage.directory(datasetURL: dataURL, datasetID: id, applicationSupportURL: support)
  try check(adjacent == dataURL.appendingPathExtension("edits").appendingPathComponent(id, isDirectory: true),
            "Local edit sidecar was not placed beside the dataset")
  let replacement = try BorgVRVolumeEditStorage.directory(datasetURL: dataURL, datasetID: UUID().uuidString,
    applicationSupportURL: support)
  try check(replacement != adjacent, "A new dataset at the same path reused an old sidecar")
  try check(try BorgVRVolumeEditStorage.directory(datasetURL: nil, datasetID: id,
    applicationSupportURL: support) == builtin, "Built-in dataset storage moved out of Application Support")
  for directory in [adjacent, replacement, builtin] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data([1]).write(to: directory.appendingPathComponent("journal"))
  }
  try Data([2]).write(to: dataURL)
  let markerURL = dataURL.deletingPathExtension().appendingPathExtension("marker")
  try Data([3]).write(to: markerURL)
  try BorgVRVolumeEditStorage.removeDataset(at: dataURL)
  try check(!FileManager.default.fileExists(atPath: dataURL.path) &&
    !FileManager.default.fileExists(atPath: dataURL.appendingPathExtension("edits").path),
    "Deleting a local dataset retained its file or one of its edit variants")
  try check(FileManager.default.fileExists(atPath: builtin.path) &&
    FileManager.default.fileExists(atPath: markerURL.path),
    "Dataset deletion removed unrelated files")
  try BorgVRVolumeEditStorage.removeDataset(at: dataURL)
  try Data([4]).write(to: dataURL)
  try BorgVRVolumeEditStorage.removeDataset(at: dataURL)
  try check(!FileManager.default.fileExists(atPath: dataURL.path),
    "Dataset deletion required an edit sidecar")
}

private func testDiscardAllEditsDuringBackgroundWork() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-discard-edits-\(UUID())")
  let parent = root.appendingPathComponent("test.data.edits")
  let directory = parent.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let source = EditTestDataset(bytesPerComponent: 2)
  let executor = try PausingHierarchyExecutor(source: source)
  let dataset = try BorgVREditableVolumeData(source: source, directory: directory, logger: nil, executor: executor)
  defer { executor.resume.signal(); dataset.stop() }
  try check(!FileManager.default.fileExists(atPath: directory.path), "Opening an unedited dataset created sidecar files")
  dataset.attachGPUBrushRenderer()
  let sphere = BorgVRVolumeBrushSample(center: .zero, radius: 100)
  let applied = DispatchSemaphore(value: 0)
  dataset.brush([sphere], mode: .erase) { _ in applied.signal() }
  try check(applied.wait(timeout: .now() + 5) == .success, "Erase did not record")
  try check(executor.entered.wait(timeout: .now() + 5) == .success, "Discard fixture did not pause a stale worker")
  try Data("Finder metadata".utf8).write(to: parent.appendingPathComponent(".DS_Store"))
  let revision = dataset.contentRevision
  let discarded = DispatchSemaphore(value: 0)
  let result = DiscardEditResult()
  dataset.discardAllEdits { error in result.lock.withLock { result.error = error }; discarded.signal() }
  try check(discarded.wait(timeout: .now() + 0.05) == .timedOut,
            "Discard removed storage before its active worker stopped")
  try check(FileManager.default.fileExists(atPath: directory.path), "Sidecars were removed while an edit job was active")
  executor.resume.signal()
  try check(discarded.wait(timeout: .now() + 5) == .success, "Discard did not finish after its active worker stopped")
  if let error = result.lock.withLock({ result.error }) { throw error }
  let snapshot = dataset.journal.snapshot()
  try check(snapshot.mask.isOriginal && snapshot.pending.isEmpty && snapshot.brickRevisions?.isEmpty == true,
            "Discard retained mask or pending edits")
  try check(dataset.contentRevision > revision && dataset.gpuBrushHistory().isEmpty,
            "Discard did not invalidate atlas contents or retained GPU operations")
  try check(!FileManager.default.fileExists(atPath: directory.path), "Discard retained the sidecar directory")
  try check(!FileManager.default.fileExists(atPath: parent.path), "Discard retained the empty dataset edits directory")
  try dataset.journal.checkpoint()
  try check(!FileManager.default.fileExists(atPath: directory.path), "An idle checkpoint recreated discarded sidecars")
  let buffer = source.allocateBrickBuffer()
  defer { buffer.deallocate() }
  for id in source.metadata.brickMetadata.indices {
    try dataset.getBrick(index: id, outputBuffer: buffer)
    try check(Array(UnsafeBufferPointer(start: buffer, count: 256)) == source.bytes(index: id, border: .clamp),
              "Discard did not immediately expose the original volume")
  }
  // Editing can continue; an old result must not overwrite the new revision.
  let next = DispatchSemaphore(value: 0)
  dataset.brush([sphere], mode: .erase) { _ in next.signal() }
  try check(next.wait(timeout: .now() + 5) == .success, "Could not edit after discarding")
  try check(dataset.journal.snapshot().revision > snapshot.revision, "Discard reused an old brush revision")
  try check(FileManager.default.fileExists(atPath: directory.appendingPathComponent("brush.journal").path),
            "New brush input did not recreate its journal")
  try dataset.journal.checkpoint()
  let reopened = try BorgVRVolumeEditJournal(directory: directory, datasetID: source.metadata.uniqueID,
    size: SIMD3(source.metadata.width, source.metadata.height, source.metadata.depth),
    spacing: SIMD3(Double(source.metadata.voxelSpacingX), Double(source.metadata.voxelSpacingY),
                  Double(source.metadata.voxelSpacingZ)), componentCount: source.metadata.componentCount)
  try check(reopened.snapshot().revision == dataset.journal.snapshot().revision && !reopened.snapshot().mask.isOriginal,
            "A new edit after discard was not durable")
  executor.resume.signal()
  let sibling = parent.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
  try Data("Finder metadata".utf8).write(to: parent.appendingPathComponent(".DS_Store"))
  let sentinel = sibling.appendingPathComponent("keep.txt")
  try Data("another dataset".utf8).write(to: sentinel)
  let discardedAgain = DispatchSemaphore(value: 0)
  dataset.discardAllEdits { error in result.lock.withLock { result.error = error }; discardedAgain.signal() }
  try check(discardedAgain.wait(timeout: .now() + 5) == .success, "A second discard did not finish")
  if let error = result.lock.withLock({ result.error }) { throw error }
  try check(!FileManager.default.fileExists(atPath: directory.path), "A second discard retained sidecars")
  try check(try Data(contentsOf: sentinel) == Data("another dataset".utf8), "Discard removed another dataset's sidecars")
  dataset.stop()
  try dataset.journal.checkpoint()
  try check(!FileManager.default.fileExists(atPath: directory.path), "Closing the dataset recreated discarded sidecars")
}

private final class EditRebuildBenchmarkSource: BORGVRDatasetProtocol {
  let m = BORGVRMetaData(width: 128, height: 96, depth: 64, componentCount: 1, bytePerComponent: 2,
    voxelSpacingX: 1, voxelSpacingY: 1, voxelSpacingZ: 1, brickSize: 16, overlap: 2,
    minValue: 2000, maxValue: 2000, compression: false, datasetDescription: "Edit benchmark", metaDescription: "")
  init() {
    for level in m.levelMetadata {
      for _ in 0..<(level.totalBricks.x * level.totalBricks.y * level.totalBricks.z) {
        m.append(offset: 0, size: 8192, minValue: 2000, maxValue: 2000)
      }
    }
  }
  func getMetadata() -> BORGVRMetaData { m }
  func allocateBrickBuffer() -> UnsafeMutablePointer<UInt8> { .allocate(capacity: 8192) }
  func newRequest() {}
  func getBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    for voxel in 0..<4096 { outputBuffer[voxel * 2] = 0xD0; outputBuffer[voxel * 2 + 1] = 7 }
  }
  func getFirstBrick(outputBuffer: UnsafeMutablePointer<UInt8>) throws { try getBrick(index: m.brickMetadata.count - 1, outputBuffer: outputBuffer) }
}

private func benchmarkEditMaterialization() throws {
  let source = EditRebuildBenchmarkSource()
  var mask = try BorgVRVolumeEditMask(size: SIMD3(128, 96, 64), spacing: SIMD3(repeating: 1))
  try mask.apply(.init(center: SIMD3(64, 48, 32), radius: 25), mode: .erase)
  let reference = try BorgVRCPUVolumeEditExecutor(source: source, border: .clamp)
  let cpu = try BorgVRVolumeEditMaterializer(source: source, usesMetal: false)
  let gpu = try BorgVRVolumeEditMaterializer(source: source)
  let m = source.m
  let ids = m.brickMetadata.indices.filter { id in
    let level = m.levelMetadata.lastIndex { $0.prevBricks <= id }!
    let layout = m.levelMetadata[level], local = id - layout.prevBricks
    let stride = m.brickSize - 2 * m.overlap
    let origin = SIMD3(local % layout.totalBricks.x, (local / layout.totalBricks.x) % layout.totalBricks.y,
      local / (layout.totalBricks.x * layout.totalBricks.y)) &* stride &- SIMD3(repeating: m.overlap)
    let low = SIMD3(max(0, origin.x), max(0, origin.y), max(0, origin.z)) &* (1 << level)
    let high = SIMD3(min(m.width, (origin.x + m.brickSize) * (1 << level)),
      min(m.height, (origin.y + m.brickSize) * (1 << level)), min(m.depth, (origin.z + m.brickSize) * (1 << level)))
    return mask.coverage(in: .init(lower: low, upper: high)) != .original
  }
  let start = Date()
  let expected = try ids.map { try reference.materialize(index: $0, mask: mask, revision: 1) }
  let referenceSeconds = Date().timeIntervalSince(start)
  var times: [Double] = []
  for (builder, metal) in [(cpu, false), (gpu, true)] {
    let began = Date()
    let actual = try ids.map { try builder.materialize(index: $0, mask: mask, revision: 1, revisions: nil,
      useGPU: metal, cached: { _, _ in nil }, store: { _ in }, isCancelled: { false }) }
    times.append(Date().timeIntervalSince(began))
    try check(zip(actual, expected).allSatisfy { $0.bytes == $1.bytes && $0.componentRanges == $1.componentRanges }, "Benchmark changed canonical voxels")
  }
  print(String(format: "Edit rebuild 128x96x64, %d edited bricks, all LODs: recursive CPU %.4fs; bottom-up CPU %.4fs (%.2fx); Metal %.4fs (%.2fx), %d GPU bricks",
    ids.count, referenceSeconds, times[0], referenceSeconds / times[0], times[1], referenceSeconds / times[1], gpu.metalBrickCount))
}

private func testCompactEditMask() throws {
  let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
  for size in [SIMD3(1, 1, 1), SIMD3(1, 9, 2), SIMD3(7, 5, 3)] {
    var mask = try BorgVRVolumeEditMask(size: size, spacing: SIMD3(0.25, 0.5, 1))
    for mode in [BorgVRVolumeBrushMode.erase, .restore] {
      try mask.apply(.init(center: SIMD3(0.6, 1.2, 1.5), radius: mode == .erase ? 0.9 : 0.3), mode: mode)
      let data = try encoder.encode(mask)
      let decoded = try PropertyListDecoder().decode(BorgVRVolumeEditMask.self, from: data)
      try check(decoded.size == mask.size && decoded.spacing == mask.spacing &&
        decoded.computeNodes() == mask.computeNodes(), "Compact mask changed geometry or physical dimensions")
      let json = try JSONEncoder().encode(mask)
      try check(try JSONDecoder().decode(BorgVRVolumeEditMask.self, from: json).computeNodes() == mask.computeNodes(),
        "JSON mask transport changed geometry")
    }
  }
  let mask = try BorgVRVolumeEditMask(size: SIMD3(2, 2, 2), spacing: SIMD3(repeating: 1))
  let data = try encoder.encode(mask)
  var container = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
  let invalidTrees: [[UInt8]] = [[], [3], [0, 1], [2], [2, 0, 0, 0, 0, 0, 0, 0, 2]]
  for invalid in invalidTrees {
    container["nodes"] = Data(invalid)
    let damaged = try PropertyListSerialization.data(fromPropertyList: container, format: .binary, options: 0)
    do {
      _ = try PropertyListDecoder().decode(BorgVRVolumeEditMask.self, from: damaged)
      throw EditTestError(message: "Malformed compact mask was accepted")
    } catch BorgVRVolumeEditError.corruptJournal {}
  }
}

private func testSourceCacheResidentEviction() throws {
  let source = EditTestDataset(bytesPerComponent: 2)
  let cache = VolumeEditSourceCache(source, budget: 512)
  let buffer = source.allocateBrickBuffer()
  defer { buffer.deallocate() }
  cache.updateResidentBrickIDs([0, 1])
  for id in [0, 1, 2] { try cache.getBrick(index: id, outputBuffer: buffer) }
  try check(cache.cachedBrick(index: 0) != nil && cache.cachedBrick(index: 1) != nil &&
    cache.cachedBrick(index: 2) == nil, "Nonresident read evicted resident originals")
  cache.updateResidentBrickIDs([0, 3])
  try cache.getBrick(index: 3, outputBuffer: buffer)
  try check(cache.cachedBrick(index: 0) != nil && cache.cachedBrick(index: 1) == nil &&
    cache.cachedBrick(index: 3) != nil, "Cache did not evict the departed resident first")
  cache.updateResidentBrickIDs([0, 3, 4])
  try cache.getBrick(index: 4, outputBuffer: buffer)
  try check(cache.cachedBrick(index: 4) != nil && [0, 3, 4].filter { cache.cachedBrick(index: $0) != nil }.count == 2,
    "All-resident cache exceeded its byte budget")
}

private func testBottomUpEditMaterialization() throws {
  if MTLCreateSystemDefaultDevice() != nil { _ = try BorgVRMetalVolumeEditProcessor() }
  for width in [1, 2, 4] {
    let source = EditTestDataset(bytesPerComponent: width)
    let m = source.getMetadata()
    var mask = try BorgVRVolumeEditMask(size: SIMD3(m.width, m.height, m.depth),
      spacing: SIMD3(Double(m.voxelSpacingX), Double(m.voxelSpacingY), Double(m.voxelSpacingZ)), componentCount: m.componentCount)
    try mask.apply(.init(center: SIMD3(0.9, 1.2, 1.4), radius: 0.85), mode: .erase)
    try mask.apply(.init(center: SIMD3(1.1, 1.2, 1.4), radius: 0.5), mode: .restore)
    let reference = try BorgVRCPUVolumeEditExecutor(source: source, border: .clamp)
    for gpu in [false, true] {
      let materializer = try BorgVRVolumeEditMaterializer(source: source, usesMetal: gpu)
      // Start with the coarsest brick to exercise on-demand bottom-up dependencies.
      for id in m.brickMetadata.indices.reversed() {
        let expected = try reference.materialize(index: id, mask: mask, revision: 2)
        let actual = try materializer.materialize(index: id, mask: mask, revision: 2, revisions: nil,
          useGPU: gpu, cached: { _, _ in nil }, store: { _ in }, isCancelled: { false })
        try check(actual.bytes == expected.bytes, "Bottom-up \(gpu ? "Metal" : "CPU") changed brick \(id), component width \(width)")
        try check(actual.componentRanges == expected.componentRanges, "Bottom-up component ranges differ")
      }
      if gpu, MTLCreateSystemDefaultDevice() != nil {
        try check(materializer.metalBrickCount > 0, "Metal processing silently fell back to CPU")
      }
    }
  }
}

private func benchmarkEditCacheOpening() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-cache-benchmark-\(UUID())")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("bricks.cache"), id = UUID()
  var seed: UInt64 = 42
  let bytes: [UInt8] = (0..<8192).map { _ in
    seed = seed &* 6364136223846793005 &+ 1
    return UInt8(truncatingIfNeeded: seed >> 32)
  }
  var cache: BorgVRVolumeEditBrickCache? = try .init(url: url, editStateID: id)
  for index in 0..<2048 {
    try cache!.store(.init(index: index, revision: 1, bytes: bytes,
      componentRanges: [.init(minValue: 0, maxValue: 255)], matchesOriginal: false), synchronize: false)
  }
  // An unclean close leaves complete current-format records but no TOC.
  try cache!.closeForRemoval(); cache = nil
  let start = Date()
  cache = try .init(url: url, editStateID: id)
  let recovery = Date().timeIntervalSince(start)
  try check(cache!.recoveredRecordCount == 2048, "Cache benchmark did not scan the initial records")
  try cache!.closeStorage(); cache = nil
  let reopen = Date()
  cache = try .init(url: url, editStateID: id)
  let indexed = Date().timeIntervalSince(reopen)
  try check(cache!.openedUsingTableOfContents && cache!.recoveredRecordCount == 0, "Cache benchmark rescanned payloads")
  let read = Date()
  for index in 0..<2048 { try check(cache!.brick(index: index, revision: 1)?.bytes == bytes, "Cache benchmark changed data") }
  let reads = Date().timeIntervalSince(read)
  try cache!.closeStorage(); cache = nil
  print(String(format: "Edit cache, 2048 bricks / 16 MiB: recovery %.4fs; TOC reopen %.4fs (%.2fx); all brick reads %.4fs",
    recovery, indexed, recovery / indexed, reads))
}

private func testReopenReusesOnlyAffectedBrickVersions() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-reopen-edits-\(UUID())")
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = EditTestDataset(bytesPerComponent: 2)
  let m = source.metadata
  let executor = try BorgVRCPUVolumeEditExecutor(source: source, border: .clamp)
  let size = SIMD3(m.width, m.height, m.depth)
  let spacing = SIMD3(Double(m.voxelSpacingX), Double(m.voxelSpacingY), Double(m.voxelSpacingZ))
  let first = BorgVRVolumeBrushSample(center: SIMD3(0.125, 0.25, 0.5), radius: 0.1)
  let second = BorgVRVolumeBrushSample(center: SIMD3(1.625, 2.25, 2.5), radius: 0.1)
  var expected = Dictionary(uniqueKeysWithValues: m.brickMetadata.indices.map {
    ($0, source.bytes(index: $0, border: .clamp))
  })
  var versions: [Int: UInt64] = [:]
  var mask = try BorgVRVolumeEditMask(size: size, spacing: spacing, componentCount: 2)
  do {
    let journal = try BorgVRVolumeEditJournal(directory: directory, datasetID: m.uniqueID, size: size, spacing: spacing, componentCount: m.componentCount)
    let cache = try BorgVRVolumeEditBrickCache(url: directory.appendingPathComponent("bricks.cache"),
                                             editStateID: journal.snapshot().editStateID)
    for (step, sample) in [first, second].enumerated() {
      let revision = UInt64(step + 1)
      try mask.apply(sample, mode: .erase)
      var changed: [Int] = []
      for id in m.brickMetadata.indices {
        let result = try executor.materialize(index: id, mask: mask, revision: revision)
        if result.bytes != expected[id] {
          changed.append(id)
          versions[id] = revision
          expected[id] = result.bytes
          try cache.store(result)
        }
      }
      try journal.append(BorgVRVolumeBrushBatch(id: UUID(), revision: revision, mode: .erase,
        samples: [sample], affectedBrickIDs: changed))
    }
    try check(versions[0] == 1 && versions[1] == nil, "Reopen fixture did not contain old and untouched bricks")
    for work in journal.snapshot().pending { journal.complete(work) }
    try journal.checkpoint()
  }
  let buffer = source.allocateBrickBuffer()
  defer { buffer.deallocate() }
  do {
    let reopened = try BorgVREditableVolumeData(source: source, directory: directory, logger: nil,
                                               executor: UnexpectedEditExecutor())
    try check(reopened.journal.snapshot().brickRevisions?[0] == 1, "Per-brick revision was not persisted")
    try check(reopened.visibilityMetadata(index: 1) != nil, "Unchanged brick lost original min/max metadata")
    try check(reopened.visibilityMetadata(index: 0) != nil, "Cached edited brick lost its min/max metadata")
    reopened.newRequest()
    // Every read must succeed immediately, including the pinned fallback and old revisions.
    try reopened.getFirstBrick(outputBuffer: buffer)
    try check(Array(UnsafeBufferPointer(start: buffer, count: 256)) == expected[m.brickMetadata.count - 1],
              "Reopening rebuilt or changed the cached fallback")
    for id in m.brickMetadata.indices {
      try reopened.getBrick(index: id, outputBuffer: buffer)
      try check(Array(UnsafeBufferPointer(start: buffer, count: 256)) == expected[id],
                "Reopened brick \(id) was missing, stale, or recomputed unnecessarily")
    }
  }
  weak var pendingClose: BorgVREditableVolumeData?
  func waitForClose() throws {
    let deadline = Date().addingTimeInterval(5)
    while pendingClose != nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    try check(pendingClose == nil, "Previous dataset still owned the edit files")
  }
  // A current SharePlay snapshot has no local per-brick cache revisions.
  let transferredDirectory = directory.appendingPathComponent("transferred")
  try BorgVRVolumeEditJournal.install(.init(datasetID: m.uniqueID, stateID: UUID(),
    revision: 2, mask: mask), in: transferredDirectory)
  do {
    let reopened = try BorgVREditableVolumeData(source: source, directory: transferredDirectory, logger: nil)
    pendingClose = reopened
    defer { reopened.stop() }
    try reopened.getBrick(index: 1, outputBuffer: buffer)
    try check(Array(UnsafeBufferPointer(start: buffer, count: 256)) == expected[1],
              "Installing a shared snapshot delayed an unchanged brick")
    try reopened.getFirstBrick(outputBuffer: buffer)
    let deadline = Date().addingTimeInterval(5)
    while true {
      do { try reopened.getBrick(index: 0, outputBuffer: buffer); break }
      catch BORGVRDataError.brickNotYetAvailable where Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    }
    try check(Array(UnsafeBufferPointer(start: buffer, count: 256)) == expected[0],
              "Installing a shared snapshot lost existing edits")
  }
  try waitForClose()
  // Leave the cache deliberately out of date. The persisted per-brick revision
  // must reject it even if the latest operation has not produced any new bricks.
  let third = BorgVRVolumeBrushSample(center: SIMD3(0.375, 0.25, 0.5), radius: 0.1)
  try mask.apply(third, mode: .erase)
  do {
    let journal = try BorgVRVolumeEditJournal(directory: directory, datasetID: m.uniqueID, size: size, spacing: spacing, componentCount: m.componentCount)
    let changed = try m.brickMetadata.indices.filter {
      try executor.materialize(index: $0, mask: mask, revision: 3).bytes != expected[$0]
    }
    try journal.append(BorgVRVolumeBrushBatch(id: UUID(), revision: 3, mode: .erase,
      samples: [third], affectedBrickIDs: changed))
    try journal.checkpoint()
  }
  do {
    let reopened = try BorgVREditableVolumeData(source: source, directory: directory, logger: nil)
    pendingClose = reopened
    defer { reopened.stop() }
    try check(reopened.gpuReadableRevision(index: 0) == nil, "Stale cached brick was advertised as ready")
    try reopened.getBrick(index: 2, outputBuffer: buffer)
    try check(Array(UnsafeBufferPointer(start: buffer, count: 256)) == expected[2],
              "An unfinished edit delayed or changed an unrelated original brick")
    do {
      try reopened.getBrick(index: 0, outputBuffer: buffer)
      throw EditTestError(message: "Reopening accepted a stale edited brick")
    } catch BORGVRDataError.brickNotYetAvailable {}
    let deadline = Date().addingTimeInterval(5)
    while true {
      do { try reopened.getBrick(index: 0, outputBuffer: buffer); break }
      catch BORGVRDataError.brickNotYetAvailable where Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    }
    let current = try executor.materialize(index: 0, mask: mask, revision: 3).bytes
    try check(Array(UnsafeBufferPointer(start: buffer, count: 256)) == current,
              "Pending reopened edit did not rebuild the correct current brick")
  }
  try waitForClose()
  // A fully restored mask bypasses stale sidecar data altogether.
  do {
    let journal = try BorgVRVolumeEditJournal(directory: directory, datasetID: m.uniqueID, size: size, spacing: spacing, componentCount: m.componentCount)
    try journal.append(BorgVRVolumeBrushBatch(id: UUID(), revision: 4, mode: .restore,
      samples: [.init(center: .zero, radius: 100)], affectedBrickIDs: Array(m.brickMetadata.indices)))
    try journal.checkpoint()
  }
  do {
    let reopened = try BorgVREditableVolumeData(source: source, directory: directory, logger: nil,
                                               executor: UnexpectedEditExecutor())
    try reopened.getFirstBrick(outputBuffer: buffer)
    for id in m.brickMetadata.indices {
      try reopened.getBrick(index: id, outputBuffer: buffer)
      try check(Array(UnsafeBufferPointer(start: buffer, count: 256)) == source.bytes(index: id, border: .clamp),
                "Fully restored volume did not use the original source directly")
    }
  }
}

private final class PausingHierarchyExecutor: BorgVRVolumeEditExecutor {
  let entered = DispatchSemaphore(value: 0)
  let resume = DispatchSemaphore(value: 0)
  let cpu: BorgVRCPUVolumeEditExecutor
  let lock = NSLock()
  private var paused = false
  private let blockedIndex: Int?

  init(source: BORGVRDatasetProtocol, blockedIndex: Int? = nil) throws {
    self.blockedIndex = blockedIndex
    cpu = try BorgVRCPUVolumeEditExecutor(source: source, border: .clamp)
  }

  func materialize(index: Int, mask: BorgVRVolumeEditMask, revision: UInt64,
                   isCancelled: @escaping () -> Bool) throws -> BorgVRMaterializedEditBrick {
    let shouldPause = lock.withLock { () -> Bool in
      guard (blockedIndex.map { $0 == index } ?? (index != 0)), revision == 1, !paused else { return false }
      paused = true
      return true
    }
    if shouldPause {
      entered.signal()
      guard resume.wait(timeout: .now() + 10) == .success else {
        throw EditTestError(message: "Timed out waiting to release hierarchy worker")
      }
    }
    return try cpu.materialize(index: index, mask: mask, revision: revision, isCancelled: isCancelled)
  }
}

private func testNewlyVisibleBrickBypassesHiddenEditWork() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-exposed-brick-\(UUID())")
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = EditTestDataset(bytesPerComponent: 2)
  let executor = try PausingHierarchyExecutor(source: source, blockedIndex: 0)
  let dataset = try BorgVREditableVolumeData(source: source, directory: directory, logger: nil, executor: executor)
  defer { executor.resume.signal(); dataset.stop() }
  dataset.attachGPUBrushRenderer()
  let recorded = DispatchSemaphore(value: 0)
  dataset.brush([.init(center: .zero, radius: 100)], mode: .erase) { _ in recorded.signal() }
  try check(recorded.wait(timeout: .now() + 5) == .success, "Brush did not record")
  try check(executor.entered.wait(timeout: .now() + 5) == .success, "Hidden brick work did not start")
  // Brick 1 was hidden when painting. Expose it while brick 0's lazy job remains
  // blocked: it must not wait for that job or be enqueued behind it.
  let buffer = dataset.allocateBrickBuffer()
  defer { buffer.deallocate() }
  let deadline = Date().addingTimeInterval(2)
  while true {
    do { try dataset.getBrick(index: 1, outputBuffer: buffer); break }
    catch BORGVRDataError.brickNotYetAvailable where Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
  }
  try check((0..<256).allSatisfy { buffer[$0] == 0 }, "Newly exposed brick did not contain the recorded edit")
  try check(dataset.gpuReadableRevision(index: 0) == nil, "The hidden fixture finished before demand could bypass it")
  let next = DispatchSemaphore(value: 0)
  dataset.brush([.init(center: .zero, radius: 100)], mode: .restore) { _ in next.signal() }
  try check(next.wait(timeout: .now() + 2) == .success, "Demand/background work blocked new brush input")
}

private func testPendingEraseVisibilityBounds() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-erase-bounds-\(UUID())")
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = EditTestDataset(bytesPerComponent: 2)
  let executor = try PausingHierarchyExecutor(source: source, blockedIndex: 0)
  let dataset = try BorgVREditableVolumeData(source: source, directory: directory, logger: nil, executor: executor)
  defer { executor.resume.signal(); dataset.stop() }
  dataset.attachGPUBrushRenderer()
  func brush(_ mode: BorgVRVolumeBrushMode) throws {
    let done = DispatchSemaphore(value: 0)
    dataset.brush([.init(center: .zero, radius: 100)], mode: mode) { _ in done.signal() }
    try check(done.wait(timeout: .now() + 5) == .success, "Visibility brush did not record")
  }
  try brush(.erase)
  try check(executor.entered.wait(timeout: .now() + 5) == .success, "Visibility fixture did not pause")
  for _ in 0..<2 {
    let bounds = dataset.visibilityMetadata(index: 0)
    try check(bounds?.minValue == 0 && bounds?.maxValue == source.metadata.brickMetadata[0].maxValue,
              "Pending erase lost conservative visibility bounds")
    try check(bounds?.componentRanges.allSatisfy { $0.minValue == 0 } == true,
              "Erase bounds did not include zero in every channel")
    try check(dataset.gpuReadableRevision(index: 0) == nil, "Visibility bounds exposed stale brick bytes")
    try brush(.erase)
  }
  try brush(.restore)
  try check(dataset.visibilityMetadata(index: 0) == nil, "Pending restore reused erase-only visibility bounds")
  try brush(.erase)
  try check(dataset.visibilityMetadata(index: 0) == nil, "Erase after pending restore reused invalid bounds")
}

private func testRestoreSkipsUneditedBricks() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-sparse-restore-\(UUID())")
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = EditTestDataset(bytesPerComponent: 2)
  let executor = try PausingHierarchyExecutor(source: source, blockedIndex: 0)
  let dataset = try BorgVREditableVolumeData(source: source, directory: directory, logger: nil, executor: executor)
  defer { executor.resume.signal(); dataset.stop() }
  dataset.attachGPUBrushRenderer()
  func brush(_ mode: BorgVRVolumeBrushMode, _ sample: BorgVRVolumeBrushSample) throws {
    let done = DispatchSemaphore(value: 0)
    let result = DiscardEditResult()
    dataset.brush([sample], mode: mode) { error in result.lock.withLock { result.error = error }; done.signal() }
    try check(done.wait(timeout: .now() + 5) == .success, "Sparse restore did not record")
    if let error = result.lock.withLock({ result.error }) { throw error }
  }
  let all = BorgVRVolumeBrushSample(center: .zero, radius: 100)
  try brush(.restore, all)
  try check(dataset.journal.snapshot().revision == 0 && dataset.contentRevision == 0 && dataset.gpuBrushHistory().isEmpty,
            "Restore on an unedited volume created work or a GPU event")
  try check(!FileManager.default.fileExists(atPath: directory.path), "No-op restore created sidecar files")

  let tiny = BorgVRVolumeBrushSample(center: SIMD3(0.125, 0.25, 0.5), radius: 0.1)
  try brush(.erase, tiny)
  try check(executor.entered.wait(timeout: .now() + 5) == .success, "Sparse edit fixture did not pause")
  let editedMask = dataset.journal.snapshot().mask
  let erasedIDs = Set(dataset.gpuBrushHistory().last!.affectedBrickIDs!)
  let beforeRestore = dataset.contentRevision
  try brush(.restore, all)
  let restoredIDs = Set(dataset.gpuBrushHistory().last!.affectedBrickIDs!)
  try check(!restoredIDs.isEmpty && restoredIDs.isSubset(of: erasedIDs) && !restoredIDs.contains(1),
            "Restore scheduled untouched bricks")
  try check(Set(dataset.changedBrickIDs(since: beforeRestore)) == restoredIDs,
            "Restore invalidated bricks outside the edited region")
  try check(dataset.visibilityMetadata(index: 1) != nil && dataset.gpuReadableRevision(index: 1) != nil,
            "Restore marked an untouched brick missing/dirty")
  let cpu = try BorgVRCPUVolumeEditExecutor(source: source, border: .clamp)
  for id in source.metadata.brickMetadata.indices {
    let edited = try cpu.materialize(index: id, mask: editedMask, revision: 1)
    if edited.bytes != source.bytes(index: id, border: .clamp) {
      try check(restoredIDs.contains(id), "Restore skipped an edited halo or coarse LOD")
    }
  }
  let revision = dataset.contentRevision
  try brush(.restore, all)
  try check(dataset.contentRevision == revision && dataset.gpuBrushHistory().count == 2,
            "Repeated restore scheduled work after the mask was already original")
}

private final class BrickUpdateActivity: @unchecked Sendable {
  let started = DispatchSemaphore(value: 0)
  let finished = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var events: [Bool] = []
  var values: [Bool] { lock.withLock { events } }

  func record(_ active: Bool) {
    lock.withLock { events.append(active) }
    if active { started.signal() } else { finished.signal() }
  }
}

private func testBrickUpdateActivity() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-edit-activity-\(UUID())")
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = EditTestDataset(bytesPerComponent: 2)
  let executor = try PausingHierarchyExecutor(source: source, blockedIndex: 0)
  let activity = BrickUpdateActivity()
  let dataset = try BorgVREditableVolumeData(source: source, directory: directory, logger: nil,
    executor: executor, backgroundWorkChanged: { activity.record($0) })
  defer { executor.resume.signal(); dataset.stop() }
  dataset.attachGPUBrushRenderer()
  try check(!dataset.hasPendingBrickUpdates, "Unedited dataset reported pending brick updates")
  let applied = DispatchSemaphore(value: 0)
  let sphere = BorgVRVolumeBrushSample(center: .zero, radius: 100)
  dataset.brush([sphere], mode: .erase) { _ in applied.signal() }
  try check(applied.wait(timeout: .now() + 5) == .success, "Activity brush did not record")
  try check(executor.entered.wait(timeout: .now() + 5) == .success, "Activity fixture did not pause")
  try check(activity.started.wait(timeout: .now() + 5) == .success && dataset.hasPendingBrickUpdates,
            "Background brick work did not activate its indicator")
  let restored = DispatchSemaphore(value: 0)
  dataset.brush([sphere], mode: .restore) { _ in restored.signal() }
  try check(restored.wait(timeout: .now() + 5) == .success, "Activity restore did not record")
  try check(activity.values == [true], "Activity notified the UI repeatedly while work remained pending")
  executor.resume.signal()
  try check(activity.finished.wait(timeout: .now() + 5) == .success && !dataset.hasPendingBrickUpdates,
            "Activity remained active after all brick updates and writes completed")
  try check(activity.values == [true, false], "Activity transitions were missing or out of order")
}

private final class DisconnectableEditSource: BORGVRDatasetProtocol {
  let source: BORGVRDatasetProtocol
  let lock = NSLock()
  private var unavailable = false
  init(_ source: BORGVRDatasetProtocol) { self.source = source }
  func disconnect() { lock.withLock { unavailable = true } }
  func newRequest() {}
  func getMetadata() -> BORGVRMetaData { source.getMetadata() }
  func allocateBrickBuffer() -> UnsafeMutablePointer<UInt8> { source.allocateBrickBuffer() }
  func getFirstBrick(outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    try getBrick(index: getMetadata().brickMetadata.count - 1, outputBuffer: outputBuffer)
  }
  func getBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    if lock.withLock({ unavailable }) { throw BORGVRDataError.brickNotYetAvailable(index: index) }
    try source.getBrick(index: index, outputBuffer: outputBuffer)
  }
  func getRawBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws -> Int? {
    if lock.withLock({ unavailable }) { throw BORGVRDataError.brickNotYetAvailable(index: index) }
    return try source.getRawBrick(index: index, outputBuffer: outputBuffer)
  }
}

private func testGPUBrushHistoryDoesNotWaitForCPUBricks() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-gpu-history-\(UUID())")
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = EditTestDataset(bytesPerComponent: 2)
  let executor = try PausingHierarchyExecutor(source: source, blockedIndex: 0)
  let dataset = try BorgVREditableVolumeData(source: source, directory: directory, logger: nil, executor: executor)
  defer { executor.resume.signal(); dataset.stop() }
  let buffer = dataset.allocateBrickBuffer()
  defer { buffer.deallocate() }
  try dataset.getBrick(index: 0, outputBuffer: buffer)
  let original = Array(UnsafeBufferPointer(start: buffer, count: 256))
  dataset.updateResidentBrickIDs([0])
  dataset.attachGPUBrushRenderer()
  // Rebuilding an atlas may briefly overlap old and new renderer lifetimes.
  dataset.attachGPUBrushRenderer()
  dataset.detachGPUBrushRenderer()
  let sphere = BorgVRVolumeBrushSample(center: .zero, radius: 100)
  let first = DispatchSemaphore(value: 0)
  dataset.brush([sphere], mode: .erase) { _ in first.signal() }
  try check(first.wait(timeout: .now() + 5) == .success, "GPU event waited for CPU materialization")
  try check(executor.entered.wait(timeout: .now() + 5) == .success, "CPU fixture did not pause")
  let second = DispatchSemaphore(value: 0)
  dataset.brush([sphere], mode: .restore) { _ in second.signal() }
  try check(second.wait(timeout: .now() + 5) == .success, "Blocked CPU hierarchy stopped GPU input")
  let history = dataset.gpuBrushHistory()
  try check(history.map(\.revision) == [1, 2] && history[0].mode == .erase && history[1].mode == .restore,
            "GPU history lost operation order")
  try check(dataset.gpuReadableRevision(index: 0) == nil, "Stale CPU brick was advertised as current")
  try check(dataset.cachedOriginalBrick(index: 0) == original, "GPU restore lost its immutable source")
  do {
    try dataset.getBrick(index: 0, outputBuffer: buffer)
    throw EditTestError(message: "Pending GPU edit returned stale CPU bytes")
  } catch BORGVRDataError.brickNotYetAvailable {}
  executor.resume.signal()
}

private func testResidentRemoteBrickCanBeEditedOffline() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-offline-resident-\(UUID())")
  defer { try? FileManager.default.removeItem(at: directory) }
  let original = EditTestDataset(bytesPerComponent: 2)
  let source = DisconnectableEditSource(original)
  let dataset = try BorgVREditableVolumeData(source: source, directory: directory, logger: nil)
  defer { dataset.stop() }
  let buffer = dataset.allocateBrickBuffer()
  defer { buffer.deallocate() }
  try dataset.getBrick(index: 0, outputBuffer: buffer)
  let originalBytes = Array(UnsafeBufferPointer(start: buffer, count: 4 * 4 * 4 * 2 * 2))
  dataset.updateResidentBrickIDs([0])
  source.disconnect()
  // This edits one core voxel whose value also occurs in a neighboring brick's halo.
  let sample = BorgVRVolumeBrushSample(center: SIMD3(0.375, 0.75, 1.5), radius: 0.1)
  let edited = DispatchSemaphore(value: 0)
  dataset.brush([sample], mode: .erase) { _ in edited.signal() }
  try check(edited.wait(timeout: .now() + 5) == .success, "Resident edit waited for a disconnected source")
  try dataset.getBrick(index: 0, outputBuffer: buffer)
  var expected = originalBytes
  let offset = (((2 * 4 + 2) * 4 + 2) * 2) * 2
  for byte in offset..<(offset + 4) { expected[byte] = 0 }
  try check(Array(UnsafeBufferPointer(start: buffer, count: expected.count)) == expected,
            "Partial resident edit downloaded neighbors or changed the wrong voxel")
  let restored = DispatchSemaphore(value: 0)
  dataset.brush([sample], mode: .restore) { _ in restored.signal() }
  try check(restored.wait(timeout: .now() + 5) == .success, "Resident restore waited for a disconnected source")
  try dataset.getBrick(index: 0, outputBuffer: buffer)
  try check(Array(UnsafeBufferPointer(start: buffer, count: expected.count)) == originalBytes,
            "Resident restore lost original values")
}

private func testResidentEditsStayReadyDuringHierarchyWork() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-resident-edit-\(UUID())")
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = EditTestDataset(bytesPerComponent: 2)
  let executor = try PausingHierarchyExecutor(source: source)
  let dataset = try BorgVREditableVolumeData(source: source, directory: directory, logger: nil, executor: executor)
  defer { executor.resume.signal(); dataset.stop() }
  dataset.updateResidentBrickIDs([0, source.metadata.brickMetadata.count - 1])
  let buffer = dataset.allocateBrickBuffer()
  defer { buffer.deallocate() }
  let sphere = BorgVRVolumeBrushSample(center: .zero, radius: 100)
  let first = DispatchSemaphore(value: 0)
  dataset.brush([sphere], mode: .erase) { _ in first.signal() }
  try check(first.wait(timeout: .now() + 5) == .success, "Resident update waited for coarse hierarchy work")
  try check(executor.entered.wait(timeout: .now() + 5) == .success, "Hierarchy fixture did not start")
  // The current data must be available synchronously without another page request.
  try dataset.getBrick(index: 0, outputBuffer: buffer)
  try check((0..<(4 * 4 * 4 * 2 * 2)).allSatisfy { buffer[$0] == 0 }, "Resident erase was not immediately available")
  let second = DispatchSemaphore(value: 0)
  dataset.brush([sphere], mode: .restore) { _ in second.signal() }
  try check(second.wait(timeout: .now() + 5) == .success, "A slow hierarchy job blocked the next brush")
  try dataset.getBrick(index: 0, outputBuffer: buffer)
  let expected = source.bytes(index: 0, border: .clamp)
  try check(Array(UnsafeBufferPointer(start: buffer, count: expected.count)) == expected,
            "Resident restore was not immediately available")
  executor.resume.signal()
}

private func testEditableDataset() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-edit-integration-\(UUID())")
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = EditTestDataset(bytesPerComponent: 2)
  let dataset = try BorgVREditableVolumeData(source: source, directory: directory, logger: nil)
  defer { dataset.stop() }
  let sphere = BorgVRVolumeBrushSample(center: .zero, radius: 100)
  let applied = DispatchSemaphore(value: 0)
  dataset.brush([sphere], mode: .erase) { _ in applied.signal() }
  try check(applied.wait(timeout: .now() + 10) == .success, "Brush worker did not finish")
  let buffer = dataset.allocateBrickBuffer()
  defer { buffer.deallocate() }
  try dataset.getFirstBrick(outputBuffer: buffer)
  try check((0..<(4 * 4 * 4 * 2 * 2)).allSatisfy { buffer[$0] == 0 }, "Renderer fallback was not edited")
  try check(!dataset.changedBrickIDs(since: 0).isEmpty, "Atlas did not receive content invalidation")
  let exported = DispatchSemaphore(value: 0)
  let box = EditExportResult()
  let output = directory.appendingPathComponent("edited.data")
  dataset.export(to: output, name: "Edited test volume", description: "Custom export description",
    progress: { value in box.lock.withLock { box.progress.append(value) } }) { result in
      box.lock.withLock { box.result = result }; exported.signal()
    }
  let restored = DispatchSemaphore(value: 0)
  dataset.brush([sphere], mode: .restore) { _ in restored.signal() }
  try check(exported.wait(timeout: .now() + 20) == .success, "Edited volume export did not finish")
  _ = try box.lock.withLock { try box.result!.get() }
  let baked = try BORGVRFileData(filename: output.path)
  try check(baked.getMetadata().uniqueID != source.metadata.uniqueID, "Baked volume reused the source UUID")
  try check(baked.getMetadata().datasetDescription == "Edited test volume" &&
            baked.getMetadata().metaDescription == "Custom export description",
            "Export did not save the requested name and description")
  try check(source.metadata.datasetDescription == "Edit test", "Export changed the source metadata")
  let progress = box.lock.withLock { box.progress }
  try check(progress.first == 0 && progress.last == 1 && zip(progress, progress.dropFirst()).allSatisfy { $0 <= $1 },
            "Export progress is missing or moved backwards")
  for index in source.metadata.brickMetadata.indices {
    try baked.getBrick(index: index, outputBuffer: buffer)
    try check((0..<(4 * 4 * 4 * 2 * 2)).allSatisfy { buffer[$0] == 0 }, "Export ignored its fixed mask snapshot")
  }
  try check(restored.wait(timeout: .now() + 10) == .success, "Restore worker did not finish")
  try dataset.getFirstBrick(outputBuffer: buffer)
  let expected = source.bytes(index: source.metadata.brickMetadata.count - 1, border: .clamp)
  try check(Array(UnsafeBufferPointer(start: buffer, count: expected.count)) == expected,
            "Restore did not replace the renderer fallback with original values")
}

private func testCancelledEditExport() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-cancel-export-\(UUID())")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let source = EditTestDataset(bytesPerComponent: 2)
  let dataset = try BorgVREditableVolumeData(source: source, directory: root.appendingPathComponent("edits"), logger: nil)
  defer { dataset.stop() }
  let token = BorgVRVolumeConversionCancellationToken()
  let output = root.appendingPathComponent("existing.data")
  let sentinel = Data("Keep the existing file".utf8)
  try sentinel.write(to: output)
  let done = DispatchSemaphore(value: 0)
  let result = EditExportResult()
  dataset.export(to: output, cancellationToken: token, progress: { value in
    if value > 0 { token.cancel() }
  }) { value in result.lock.withLock { result.result = value }; done.signal() }
  try check(done.wait(timeout: .now() + 5) == .success, "Cancelled export did not finish")
  do {
    _ = try result.lock.withLock { try result.result!.get() }
    throw EditTestError(message: "Cancelled export reported success")
  } catch is CancellationError {}
  try check(try Data(contentsOf: output) == sentinel, "Cancelled export modified an existing destination")
  let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
    .filter { $0.hasPrefix(".") && $0.hasSuffix(".data") }
  try check(leftovers.isEmpty, "Cancelled export retained a partial output file")

  let retry = DispatchSemaphore(value: 0)
  dataset.export(to: root.appendingPathComponent("retry.data")) { value in
    result.lock.withLock { result.result = value }; retry.signal()
  }
  try check(retry.wait(timeout: .now() + 5) == .success, "Could not export again after cancellation")
  _ = try result.lock.withLock { try result.result!.get() }

  let remoteToken = BorgVRVolumeConversionCancellationToken()
  let remote = try BorgVREditableVolumeData(source: UnavailableEditDataset(source, onRead: { remoteToken.cancel() }),
    directory: root.appendingPathComponent("remote-edits"), logger: nil)
  defer { remote.stop() }
  let remoteDone = DispatchSemaphore(value: 0)
  let remoteOutput = root.appendingPathComponent("remote.data")
  remote.export(to: remoteOutput, cancellationToken: remoteToken) { value in
    result.lock.withLock { result.result = value }; remoteDone.signal()
  }
  try check(remoteDone.wait(timeout: .now() + 5) == .success, "Cancel waited for the remote brick timeout")
  do {
    _ = try result.lock.withLock { try result.result!.get() }
    throw EditTestError(message: "Cancelled remote export reported success")
  } catch is CancellationError {}
  try check(!FileManager.default.fileExists(atPath: remoteOutput.path), "Cancelled remote export created an output file")
}

private final class RawOnlyExportSource: BORGVRDatasetProtocol {
  let file: BORGVRFileData
  private let lock = NSLock()
  private var rawReads = 0
  var rawReadCount: Int { lock.withLock { rawReads } }
  init(_ file: BORGVRFileData) { self.file = file }
  func newRequest() {}
  func getMetadata() -> BORGVRMetaData { file.getMetadata() }
  func allocateBrickBuffer() -> UnsafeMutablePointer<UInt8> { file.allocateBrickBuffer() }
  func getBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    throw EditTestError(message: "Export decoded an unchanged source brick")
  }
  func getFirstBrick(outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    throw EditTestError(message: "Export decoded the original fallback brick")
  }
  func getRawBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws -> Int? {
    lock.withLock { rawReads += 1 }
    return try file.getRawBrick(index: index, outputBuffer: outputBuffer)
  }
}

func makeEditExportSource(_ source: EditTestDataset, compressed: Bool, url: URL) throws -> BORGVRFileData {
  let m = source.metadata
  let metadata = BORGVRMetaData(width: m.width, height: m.height, depth: m.depth,
    componentCount: m.componentCount, bytePerComponent: m.bytesPerComponent,
    voxelSpacingX: m.voxelSpacingX, voxelSpacingY: m.voxelSpacingY, voxelSpacingZ: m.voxelSpacingZ,
    brickSize: m.brickSize, overlap: m.overlap, minValue: m.minValue, maxValue: m.maxValue,
    compression: compressed, datasetDescription: m.datasetDescription, metaDescription: m.metaDescription)
  var data = Data(repeating: 0, count: 8)
  for index in m.brickMetadata.indices {
    let raw = source.bytes(index: index, border: .clamp)
    var bytes = Data(raw)
    if compressed && index != 1 {
      var output = [UInt8](repeating: 0, count: raw.count)
      let count = raw.withUnsafeBufferPointer { input in
        output.withUnsafeMutableBufferPointer { destination in
          compression_encode_buffer(destination.baseAddress!, destination.count,
            input.baseAddress!, input.count, nil, COMPRESSION_LZ4)
        }
      }
      if count > 0, count < raw.count { bytes = Data(output.prefix(count)) }
    }
    metadata.append(offset: data.count, size: bytes.count, minValue: m.minValue, maxValue: m.maxValue)
    data.append(bytes)
  }
  let header = Data(from: UInt64(data.count))
  data.replaceSubrange(0..<8, with: header)
  data.append(metadata.toData())
  try data.write(to: url)
  return try BORGVRFileData(filename: url.path)
}

private func testRawEditExport() throws {
  for compressed in [false, true] {
    for width in [1, 2, 4] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-raw-export-\(UUID())")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let source = EditTestDataset(bytesPerComponent: width)
      let channelValues = Array(source.levels[0].prefix(2))
      source.levels[0] = source.levels[0].indices.map { channelValues[$0 % 2] }
      source.rebuildLevels()
      let file = try makeEditExportSource(source, compressed: compressed, url: root.appendingPathComponent("source.data"))
      let m = file.getMetadata()
      let wrapped = RawOnlyExportSource(file)
      let edits = root.appendingPathComponent("sidecar")
      var expected: [Int: BorgVRMaterializedEditBrick] = [:]
      var saved: [Int: BorgVRVolumeEditBrickCache.Record] = [:]
      do {
        let journal = try BorgVRVolumeEditJournal(directory: edits, datasetID: m.uniqueID,
          size: SIMD3(m.width, m.height, m.depth),
          spacing: SIMD3(Double(m.voxelSpacingX), Double(m.voxelSpacingY), Double(m.voxelSpacingZ)), componentCount: m.componentCount)
        try journal.append(.init(id: UUID(), revision: 1, mode: .erase,
          samples: [.init(center: SIMD3(0.125, 0.25, 0.5), radius: 0.1)],
          affectedBrickIDs: Array(m.brickMetadata.indices)))
        try journal.checkpoint()
        let cache = try BorgVRVolumeEditBrickCache(url: edits.appendingPathComponent("bricks.cache"),
          editStateID: journal.snapshot().editStateID)
        let cpu = try BorgVRCPUVolumeEditExecutor(source: file, border: .clamp)
        for index in m.brickMetadata.indices {
          let brick = try cpu.materialize(index: index, mask: journal.snapshot().mask, revision: 1)
          expected[index] = brick
          try cache.store(brick)
          saved[index] = try cache.storedBrick(index: index, revision: 1)
        }
      }
      let dataset = try BorgVREditableVolumeData(source: wrapped, directory: edits, logger: nil,
        executor: UnexpectedEditExecutor())
      defer { dataset.stop() }
      let done = DispatchSemaphore(value: 0)
      let result = EditExportResult()
      let output = root.appendingPathComponent("export.data")
      dataset.export(to: output) { value in result.lock.withLock { result.result = value }; done.signal() }
      try check(done.wait(timeout: .now() + 5) == .success, "Raw/sidecar export did not finish")
      _ = try result.lock.withLock { try result.result!.get() }
      let exported = try BORGVRFileData(filename: output.path)
      try check(exported.getMetadata().compression == compressed, "Export changed the source compression setting")
      try check(wrapped.rawReadCount > 0, "Unchanged bricks did not use raw access")
      if compressed && width > 1 {
        try check(m.brickMetadata.contains { $0.size < source.bytes(index: 0, border: .clamp).count },
                  "Compressed export fixture contained no compressed source bricks")
        try check(saved.values.contains { $0.compressed }, "Sidecar fixture contained no compressed edited bricks")
      }
      let buffer = file.allocateBrickBuffer()
      defer { buffer.deallocate() }
      for index in m.brickMetadata.indices {
        let expectedBrick = expected[index]!
        try exported.getBrick(index: index, outputBuffer: buffer)
        try check(Array(UnsafeBufferPointer(start: buffer, count: expectedBrick.bytes.count)) == expectedBrick.bytes,
                  "Optimized export changed voxels, overlap, or LOD values")
        _ = try exported.getRawBrick(index: index, outputBuffer: buffer)
        let copied = Data(bytes: buffer, count: exported.getMetadata().brickMetadata[index].size)
        if expectedBrick.matchesOriginal {
          _ = try file.getRawBrick(index: index, outputBuffer: buffer)
          try check(copied == Data(bytes: buffer, count: m.brickMetadata[index].size),
                    "Unchanged source payload was recompressed or changed")
        } else if compressed {
          try check(copied == saved[index]!.payload, "A ready sidecar payload was decompressed/recompressed")
        }
      }
    }
  }
}

private func testPendingCompressedEditExport() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-pending-export-\(UUID())")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let source = EditTestDataset(bytesPerComponent: 2)
  let channels = Array(source.levels[0].prefix(2))
  source.levels[0] = source.levels[0].indices.map { channels[$0 % 2] }
  source.rebuildLevels()
  let file = try makeEditExportSource(source, compressed: true, url: root.appendingPathComponent("source.data"))
  let m = file.getMetadata()
  let edits = root.appendingPathComponent("sidecar")
  do {
    let journal = try BorgVRVolumeEditJournal(directory: edits, datasetID: m.uniqueID,
      size: SIMD3(m.width, m.height, m.depth),
      spacing: SIMD3(Double(m.voxelSpacingX), Double(m.voxelSpacingY), Double(m.voxelSpacingZ)), componentCount: m.componentCount)
    try journal.append(.init(id: UUID(), revision: 1, mode: .erase,
      samples: [.init(center: SIMD3(0.125, 0.25, 0.5), radius: 0.1)],
      affectedBrickIDs: Array(m.brickMetadata.indices)))
    let cache = try BorgVRVolumeEditBrickCache(url: edits.appendingPathComponent("bricks.cache"),
      editStateID: journal.snapshot().editStateID)
    let cpu = try BorgVRCPUVolumeEditExecutor(source: file, border: .clamp)
    for index in m.brickMetadata.indices {
      try cache.store(cpu.materialize(index: index, mask: journal.snapshot().mask, revision: 1))
    }
    // The journal advances while every cached brick is still at the old revision.
    try journal.append(.init(id: UUID(), revision: 2, mode: .erase,
      samples: [.init(center: .zero, radius: 100)], affectedBrickIDs: Array(m.brickMetadata.indices)))
    try journal.checkpoint()
  }
  let wrapped = RawOnlyExportSource(file)
  let dataset = try BorgVREditableVolumeData(source: wrapped, directory: edits, logger: nil)
  defer { dataset.stop() }
  let done = DispatchSemaphore(value: 0)
  let result = EditExportResult()
  let output = root.appendingPathComponent("new.data")
  dataset.export(to: output) { value in result.lock.withLock { result.result = value }; done.signal() }
  try check(done.wait(timeout: .now() + 5) == .success, "Pending compressed export did not finish")
  _ = try result.lock.withLock { try result.result!.get() }
  let exported = try BORGVRFileData(filename: output.path)
  let buffer = exported.allocateBrickBuffer()
  defer { buffer.deallocate() }
  try check(exported.getMetadata().compression, "Pending computed bricks lost LZ4 compression")
  for index in m.brickMetadata.indices {
    try exported.getBrick(index: index, outputBuffer: buffer)
    try check((0..<256).allSatisfy { buffer[$0] == 0 }, "Export reused a stale sidecar brick")
    try check(exported.getMetadata().brickMetadata[index].size < 256, "A newly computed zero brick was not compressed")
  }
  try check(wrapped.rawReadCount == 0, "A fully erased export unnecessarily read its original bricks")
}

private final class BulkRawExportSource: BORGVRDatasetProtocol {
  let metadata = BORGVRMetaData(width: 256, height: 256, depth: 128, componentCount: 1,
    bytePerComponent: 1, voxelSpacingX: 1, voxelSpacingY: 1, voxelSpacingZ: 1,
    brickSize: 32, overlap: 0, minValue: 0, maxValue: 255, compression: false,
    datasetDescription: "Chunk boundary test", metaDescription: "")
  init() {
    for level in metadata.levelMetadata {
      for _ in 0..<(level.totalBricks.x * level.totalBricks.y * level.totalBricks.z) {
        let value = Int(UInt8(truncatingIfNeeded: metadata.brickMetadata.count))
        metadata.append(offset: 8 + metadata.brickMetadata.count * 32768, size: 32768,
          minValue: value, maxValue: value)
      }
    }
  }
  func newRequest() {}
  func getMetadata() -> BORGVRMetaData { metadata }
  func allocateBrickBuffer() -> UnsafeMutablePointer<UInt8> { .allocate(capacity: 32768) }
  func getBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    throw EditTestError(message: "Bulk raw export decoded a brick")
  }
  func getFirstBrick(outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    throw EditTestError(message: "Bulk raw export decoded its fallback")
  }
  func getRawBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws -> Int? {
    outputBuffer.update(repeating: UInt8(truncatingIfNeeded: index), count: 32768)
    return 32768
  }
}

private func testLargeRawExport() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-bulk-export-\(UUID())")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let source = BulkRawExportSource()
  let dataset = try BorgVREditableVolumeData(source: source, directory: root.appendingPathComponent("edits"),
    logger: nil, executor: UnexpectedEditExecutor())
  defer { dataset.stop() }
  let done = DispatchSemaphore(value: 0)
  let result = EditExportResult()
  let output = root.appendingPathComponent("large.data")
  dataset.export(to: output) { value in result.lock.withLock { result.result = value }; done.signal() }
  try check(done.wait(timeout: .now() + 10) == .success, "Chunked export did not finish")
  _ = try result.lock.withLock { try result.result!.get() }
  let file = try BORGVRFileData(filename: output.path)
  let buffer = file.allocateBrickBuffer()
  defer { buffer.deallocate() }
  var end = 8
  for index in file.getMetadata().brickMetadata.indices {
    let entry = file.getMetadata().brickMetadata[index]
    try check(entry.offset == end, "Chunk flush changed payload offsets")
    end += entry.size
    try file.getBrick(index: index, outputBuffer: buffer)
    try check((0..<32768).allSatisfy { buffer[$0] == UInt8(truncatingIfNeeded: index) },
              "Chunked export corrupted a brick")
  }
  try check(end > 8 * 1024 * 1024, "Chunk test never crossed the write-buffer boundary")
}

private func testOfflineCachedExport() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-offline-export-\(UUID())")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let original = EditTestDataset(bytesPerComponent: 2)
  let source = DisconnectableEditSource(original)
  let dataset = try BorgVREditableVolumeData(source: source, directory: root.appendingPathComponent("edits"), logger: nil)
  defer { dataset.stop() }
  let buffer = dataset.allocateBrickBuffer()
  defer { buffer.deallocate() }
  for index in original.metadata.brickMetadata.indices { try dataset.getBrick(index: index, outputBuffer: buffer) }
  source.disconnect()
  let done = DispatchSemaphore(value: 0)
  let result = EditExportResult()
  let output = root.appendingPathComponent("offline.data")
  dataset.export(to: output) { value in result.lock.withLock { result.result = value }; done.signal() }
  try check(done.wait(timeout: .now() + 5) == .success, "Export ignored available original RAM bricks after disconnect")
  _ = try result.lock.withLock { try result.result!.get() }
  let file = try BORGVRFileData(filename: output.path)
  for index in original.metadata.brickMetadata.indices {
    try file.getBrick(index: index, outputBuffer: buffer)
    try check(Array(UnsafeBufferPointer(start: buffer, count: 256)) == original.bytes(index: index, border: .clamp),
              "Offline export changed cached original bytes")
  }
}

private func testEditCache() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-edit-cache-\(UUID())")
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("bricks.cache")
  let stateID = UUID()
  var cache: BorgVRVolumeEditBrickCache? = try BorgVRVolumeEditBrickCache(url: url, editStateID: stateID)
  let values = (0..<4096).map { UInt8(truncatingIfNeeded: $0 * 37) }
  for revision in 1...5 {
    try cache!.store(BorgVRMaterializedEditBrick(index: 3, revision: UInt64(revision),
      bytes: values, componentRanges: [BORGVRComponentRange(minValue: 0, maxValue: 255)], matchesOriginal: false))
  }
  try cache!.store(BorgVRMaterializedEditBrick(index: 4, revision: 5, bytes: [UInt8](repeating: 0, count: 8192),
    componentRanges: [BORGVRComponentRange(minValue: 0, maxValue: 0)], matchesOriginal: false))
  try check(try cache!.brick(index: 4, revision: 5)?.bytes == [UInt8](repeating: 0, count: 8192), "Zero brick did not decompress")
  let before = try Data(contentsOf: url).count
  try cache!.compact()
  let after = try Data(contentsOf: url).count
  try check(after < before, "In-place compaction did not reclaim obsolete versions")
  cache = nil
  cache = try BorgVRVolumeEditBrickCache(url: url, editStateID: stateID)
  try check(try cache!.brick(index: 3, revision: 5)?.bytes == values, "Compaction/reopen changed brick bytes")
  try check(try cache!.brick(index: 3, revision: 4) == nil, "Stale cache revision was returned")
  try cache!.store(BorgVRMaterializedEditBrick(index: 3, revision: 6, bytes: [], componentRanges: [], matchesOriginal: true))
  cache = nil
  cache = try BorgVRVolumeEditBrickCache(url: url, editStateID: stateID)
  try check(try cache!.brick(index: 3, revision: 6) == nil, "Restore resurrected a cached deletion")
  cache = nil
  let file = try FileHandle(forWritingTo: url)
  try file.seek(toOffset: 8)
  try file.write(contentsOf: Data([1]))
  try file.close()
  cache = try BorgVRVolumeEditBrickCache(url: url, editStateID: stateID)
  try check(try cache!.brick(index: 4, revision: 5) == nil, "Interrupted compaction was not discarded")
  try cache!.closeForRemoval()
  try FileManager.default.removeItem(at: directory)
  try cache!.compactIfNeeded()
  try cache!.compact()
  try check(!FileManager.default.fileExists(atPath: directory.path), "Idle cache maintenance recreated removed sidecars")
  try cache!.store(BorgVRMaterializedEditBrick(index: 3, revision: 7, bytes: values,
    componentRanges: [BORGVRComponentRange(minValue: 0, maxValue: 255)], matchesOriginal: false))
  try check(try cache!.brick(index: 3, revision: 7)?.bytes == values, "Cache did not reopen after storage removal")
  let raw = (0..<64).map(UInt8.init)
  try cache!.store(.init(index: 8, revision: 7, bytes: raw,
    componentRanges: [.init(minValue: 0, maxValue: 63)], matchesOriginal: false))
  try check(try cache!.storedBrick(index: 8, revision: 7)?.compressed == false, "Raw cache fixture compressed unexpectedly")
  let output = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
  defer { output.deallocate() }
  _ = try cache!.readBrick(index: 8, revision: 7, into: output, byteCount: 64)
  try check(Array(UnsafeBufferPointer(start: output, count: 64)) == raw, "Direct raw-brick upload changed bytes")
  do {
    _ = try cache!.readBrick(index: 8, revision: 7, into: output, byteCount: 63)
    throw EditTestError(message: "Cache read accepted an undersized destination")
  } catch BorgVRVolumeEditError.invalidBufferSize {}
  cache = nil
}

private func testEditCacheTableOfContents() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-edit-toc-\(UUID())")
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("bricks.cache"), stateID = UUID()
  let values = (0..<4096).map { UInt8(truncatingIfNeeded: $0 * 37) }
  let brick = BorgVRMaterializedEditBrick(index: 0, revision: 1, bytes: values,
    componentRanges: [.init(minValue: 0, maxValue: 255)], matchesOriginal: false)
  var cache: BorgVRVolumeEditBrickCache? = try .init(url: url, editStateID: stateID)
  try cache!.store(brick)
  try cache!.store(.init(index: 0, revision: 2, bytes: values, componentRanges: brick.componentRanges, matchesOriginal: false))
  try cache!.closeStorage()
  cache = nil
  cache = try .init(url: url, editStateID: stateID)
  try check(cache!.openedUsingTableOfContents && cache!.recoveredRecordCount == 0, "Clean cache reopen scanned brick payloads")
  try check(try cache!.brick(index: 0, revision: 2)?.bytes == values, "TOC lookup changed the current brick")
  try cache!.closeStorage()
  cache = nil

  // A missing footer must recover all complete records and persist a fresh TOC.
  let file = try FileHandle(forUpdating: url)
  let size = try file.seekToEnd()
  try file.truncate(atOffset: size - 56)
  try file.close()
  cache = try .init(url: url, editStateID: stateID)
  try check(!cache!.openedUsingTableOfContents && cache!.recoveredRecordCount == 2, "Cache did not recover a missing TOC")
  try check(try cache!.brick(index: 0, revision: 2)?.bytes == values, "Missing-TOC recovery lost the newest record")
  try cache!.closeStorage()
  cache = nil

  let damagedTable = try FileHandle(forUpdating: url)
  let end = try damagedTable.seekToEnd()
  try damagedTable.seek(toOffset: end - 1)
  let byte = try damagedTable.read(upToCount: 1)![0]
  try damagedTable.seek(toOffset: end - 1)
  try damagedTable.write(contentsOf: Data([byte ^ 0xFF]))
  try damagedTable.close()
  cache = try .init(url: url, editStateID: stateID)
  try check(!cache!.openedUsingTableOfContents && cache!.recoveredRecordCount == 2, "Damaged TOC discarded recoverable brick data")
  try cache!.store(.init(index: 1, revision: 3, bytes: values, componentRanges: brick.componentRanges, matchesOriginal: false))
  // Simulate a process dying during an append, without a final TOC flush.
  try cache!.closeForRemoval()
  cache = nil
  let torn = try FileHandle(forUpdating: url)
  try torn.truncate(atOffset: torn.seekToEnd() - 7)
  try torn.close()
  cache = try .init(url: url, editStateID: stateID)
  try check(cache!.recoveredRecordCount == 2 && cache!.summary(index: 1, revision: 3) == nil, "Torn cache tail was accepted")
  try check(try cache!.brick(index: 0, revision: 2)?.bytes == values, "Torn append lost the valid prefix")
  try cache!.closeStorage()
  cache = nil

  // Opening must not examine obsolete payloads, even if one became unreadable.
  let obsolete = try FileHandle(forUpdating: url)
  let firstPayload: UInt64 = 25 + 96 + 16
  try obsolete.seek(toOffset: firstPayload)
  let old = try obsolete.read(upToCount: 1)![0]
  try obsolete.seek(toOffset: firstPayload)
  try obsolete.write(contentsOf: Data([old ^ 0xFF]))
  try obsolete.close()
  cache = try .init(url: url, editStateID: stateID)
  try check(cache!.openedUsingTableOfContents && cache!.recoveredRecordCount == 0, "Opening inspected obsolete payloads")
  try check(try cache!.brick(index: 0, revision: 2)?.bytes == values, "Obsolete payload corruption affected the current record")
  // Corruption of a live payload is detected only on access, then invalidated.
  try cache!.store(.init(index: 2, revision: 4, bytes: values, componentRanges: brick.componentRanges, matchesOriginal: false))
  try cache!.closeStorage()
  cache = nil
  let live = try FileHandle(forUpdating: url)
  let length = try live.seekToEnd()
  try live.seek(toOffset: length - 48)
  let tableOffset = try live.read(upToCount: 8)!.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
  try live.seek(toOffset: tableOffset - 1)
  let last = try live.read(upToCount: 1)![0]
  try live.seek(toOffset: tableOffset - 1)
  try live.write(contentsOf: Data([last ^ 0xFF]))
  try live.close()
  cache = try .init(url: url, editStateID: stateID)
  do {
    _ = try cache!.brick(index: 2, revision: 4)
    throw EditTestError(message: "A damaged live payload passed its checksum")
  } catch BorgVRVolumeEditError.corruptJournal {}
  try check(cache!.summary(index: 2, revision: 4) == nil, "Corrupt payload remained advertised as ready")
  try cache!.store(.init(index: 2, revision: 4, bytes: values, componentRanges: brick.componentRanges, matchesOriginal: false))
  try check(try cache!.brick(index: 2, revision: 4)?.bytes == values, "A damaged cache entry could not be replaced")
  try cache!.closeStorage(); cache = nil

  cache = try .init(url: url, editStateID: stateID)
  try cache!.compact()
  try cache!.closeStorage(); cache = nil
  cache = try .init(url: url, editStateID: stateID)
  try check(cache!.openedUsingTableOfContents && cache!.brick(index: 2, revision: 4)?.bytes == values,
    "Compaction lost the current cache TOC")
}

private func testTransientEditSnapshot(size: SIMD3<Int>, spacing: SIMD3<Double>, sphere: BorgVRVolumeBrushSample) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-transient-edit-\(UUID())")
  defer { try? FileManager.default.removeItem(at: directory) }
  let datasetID = UUID().uuidString, stateID = UUID(), previousOperation = UUID()
  let snapshot = BorgVRVolumeEditSnapshot(datasetID: datasetID, stateID: stateID, revision: 7,
    mask: try BorgVRVolumeEditMask(size: size, spacing: spacing), operationIDs: [previousOperation])
  var journal = try BorgVRVolumeEditJournal(directory: directory, datasetID: datasetID,
    size: size, spacing: spacing, initialSnapshot: snapshot)
  try journal.checkpoint()
  try journal.closeStorage()
  try check(!FileManager.default.fileExists(atPath: directory.path), "An untouched shared snapshot created sidecar storage")
  let transient = journal.transferableSnapshot(datasetID: datasetID)
  try check(transient.stateID == stateID && transient.revision == 7 && transient.operationIDs == [previousOperation],
    "Transient snapshot lost its shared epoch, revision or operation IDs")
  let batch = BorgVRVolumeBrushBatch(id: UUID(), revision: 8, mode: .erase, samples: [sphere], affectedBrickIDs: [0])
  try journal.append(batch)
  try journal.closeStorage()
  journal = try .init(directory: directory, datasetID: datasetID, size: size, spacing: spacing)
  let persisted = journal.transferableSnapshot(datasetID: datasetID)
  try check(persisted.stateID == stateID && persisted.revision == 8 && !persisted.mask.isOriginal &&
    persisted.operationIDs == [previousOperation, batch.id], "First edit did not persist the shared snapshot correctly")
  do {
    _ = try BorgVRVolumeEditJournal(directory: directory, datasetID: datasetID, size: size, spacing: spacing,
      initialSnapshot: snapshot)
    throw EditTestError(message: "Snapshot installation overwrote an existing journal")
  } catch BorgVRVolumeEditError.invalidRevision {}
  try journal.closeStorage()
}

private func testEditJournal(size: SIMD3<Int>, spacing: SIMD3<Double>, sphere: BorgVRVolumeBrushSample) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-edit-\(UUID())")
  defer { try? FileManager.default.removeItem(at: directory) }
  let batch = BorgVRVolumeBrushBatch(id: UUID(), revision: 1, mode: .erase, samples: [sphere], affectedBrickIDs: [0, 1])
  var journal: BorgVRVolumeEditJournal? = try BorgVRVolumeEditJournal(
    directory: directory, datasetID: "test", size: size, spacing: spacing)
  try journal!.append(batch)
  try journal!.append(batch)
  let oldWork = journal!.snapshot().pending[0]
  try journal!.append(BorgVRVolumeBrushBatch(id: UUID(), revision: 2, mode: .erase,
    samples: [sphere], affectedBrickIDs: [1, 2]))
  journal!.complete(oldWork)
  try check(journal!.snapshot().pending.count == 1, "Old worker cleared newer work")
  try check(journal!.snapshot().brickRevisions == [0: 1, 1: 2, 2: 2], "Journal lost independent brick revisions")
  try journal!.checkpoint()
  try journal!.append(BorgVRVolumeBrushBatch(id: UUID(), revision: 3, mode: .restore,
    samples: [sphere], affectedBrickIDs: [0, 1]))
  journal = nil
  let handle = try FileHandle(forWritingTo: directory.appendingPathComponent("brush.journal"))
  try handle.seekToEnd()
  try handle.write(contentsOf: Data([1, 2, 3]))
  try handle.close()
  journal = try BorgVRVolumeEditJournal(directory: directory, datasetID: "test", size: size, spacing: spacing)
  try check(journal!.snapshot().revision == 3 && journal!.snapshot().mask.isOriginal,
            "Checkpoint/torn-tail recovery lost restore")
  try check(journal!.snapshot().brickRevisions == [0: 3, 1: 3, 2: 2],
            "Journal replay did not restore per-brick revisions")
  try check(!journal!.snapshot().pending.isEmpty, "Restore lost atlas invalidation work")
  let work = journal!.snapshot().pending[0]
  journal!.complete(work)
  try journal!.checkpoint()
  journal = nil
  journal = try BorgVRVolumeEditJournal(directory: directory, datasetID: "test", size: size, spacing: spacing)
  try check(journal!.snapshot().pending.isEmpty, "Completed work was not checkpointed")
  do {
    try journal!.append(BorgVRVolumeBrushBatch(id: UUID(), revision: 5, mode: .erase, samples: [sphere]))
    throw EditTestError(message: "Revision gap accepted")
  } catch BorgVRVolumeEditError.invalidRevision {}
  try journal!.checkpoint()
  journal = nil
  let checkpointURL = directory.appendingPathComponent("mask.checkpoint")
  let checkpointHandle = try FileHandle(forReadingFrom: checkpointURL)
  defer { try? checkpointHandle.close() }
  let inode = try FileManager.default.attributesOfItem(atPath: checkpointURL.path)[.systemFileNumber] as! NSNumber
  journal = try .init(directory: directory, datasetID: "test", size: size, spacing: spacing)
  try journal!.checkpoint()
  try journal!.closeStorage()
  journal = nil
  let reopenedInode = try FileManager.default.attributesOfItem(atPath: checkpointURL.path)[.systemFileNumber] as! NSNumber
  try check(inode == reopenedInode, "Opening/closing an unchanged edit state rewrote its mask checkpoint")
}
