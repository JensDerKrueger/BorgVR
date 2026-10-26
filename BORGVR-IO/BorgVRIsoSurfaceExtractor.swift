import Foundation
import simd

/// Extracts the level-zero isosurface of a BorgVR dataset and writes it as an OBJ mesh.
enum BorgVRIsoSurfaceExtractor {
  struct Result: Sendable {
    let outputURL: URL
    let vertexCount: Int
    let triangleCount: Int
  }

  final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
      lock.withLock { cancelled = true }
    }

    func checkCancellation() throws {
      if lock.withLock({ cancelled }) || Task.isCancelled {
        throw CancellationError()
      }
    }
  }

  enum Error: Swift.Error, LocalizedError {
    case invalidMetadata(String)
    case unsupportedComponentSize(Int)
    case noSurface
    case outputSizeOverflow

    var errorDescription: String? {
      switch self {
        case .invalidMetadata(let reason):
          return String(
            format: String(localized: "The BorgVR dataset metadata is invalid: %@."),
            reason
          )
        case .unsupportedComponentSize(let size):
          return String(
            format: String(localized: "Cannot extract an isosurface from %d-byte components."),
            size
          )
        case .noSurface:
          return String(localized: "The selected isovalue does not intersect the dataset.")
        case .outputSizeOverflow:
          return String(localized: "The extracted surface is too large for this system.")
      }
    }
  }

  private struct Vertex: Sendable {
    let position: SIMD3<Double>
    let normal: SIMD3<Double>
  }

  private struct BrickJob: Sendable {
    let brickX: Int
    let brickY: Int
    let brickZ: Int
    let origin: SIMD3<Int>
    let cellEnd: SIMD3<Int>
    let shouldProcess: Bool
  }

  private struct BrickMesh: Sendable {
    var vertices: [Vertex] = []
    var triangles: [SIMD3<Int>] = []
  }

  private struct BrickFragment: Sendable {
    let vertices: String
    let faces: String
  }

  private final class ExtractionContext: @unchecked Sendable {
    let dataset: BORGVRDatasetProtocol
    let metadata: BORGVRMetaData
    let threshold: Double
    let volumeSize: Vec3<Int>
    let spacing: SIMD3<Double>
    let cancellationToken: CancellationToken?
    let metalBackend: MetalBackendState

    init(
      dataset: BORGVRDatasetProtocol,
      metadata: BORGVRMetaData,
      threshold: Double,
      volumeSize: Vec3<Int>,
      spacing: SIMD3<Double>,
      cancellationToken: CancellationToken?,
      metalBackend: MetalBackendState
    ) {
      self.dataset = dataset
      self.metadata = metadata
      self.threshold = threshold
      self.volumeSize = volumeSize
      self.spacing = spacing
      self.cancellationToken = cancellationToken
      self.metalBackend = metalBackend
    }
  }

  private final class MetalBackendState: @unchecked Sendable {
    private let lock = NSLock()
    private let logger: LoggerBase?
    private var backend: BorgVRMetalIsoSurfaceClassifier?
    private var successfulBrickCount = 0
    private var reportedFailure = false

    init(_ backend: BorgVRMetalIsoSurfaceClassifier?, logger: LoggerBase?) {
      self.backend = backend
      self.logger = logger
    }

    func current() -> BorgVRMetalIsoSurfaceClassifier? {
      lock.withLock { backend }
    }

    func recordSuccess() {
      lock.withLock { successfulBrickCount += 1 }
    }

    func disable(after error: Swift.Error) {
      let shouldReport = lock.withLock {
        backend = nil
        guard !reportedFailure else { return false }
        reportedFailure = true
        return true
      }
      if shouldReport {
        logger?.warning(
          "Metal isosurface classification failed; continuing on the CPU: " +
          error.localizedDescription
        )
      }
    }

    var didUseMetal: Bool {
      lock.withLock { successfulBrickCount > 0 }
    }
  }

  private final class MeshBatchStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var meshes: [BrickMesh?]
    private var firstError: Swift.Error?

    init(count: Int) {
      meshes = Array(repeating: nil, count: count)
    }

    func store(_ mesh: BrickMesh, at index: Int) {
      lock.withLock { meshes[index] = mesh }
    }

    func store(error: Swift.Error) {
      lock.withLock {
        if firstError == nil { firstError = error }
      }
    }

    func result() throws -> [BrickMesh] {
      try lock.withLock {
        if let firstError { throw firstError }
        return meshes.map { $0 ?? BrickMesh() }
      }
    }
  }

  private final class FragmentBatchStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var fragments: [BrickFragment?]

    init(count: Int) {
      fragments = Array(repeating: nil, count: count)
    }

    func store(_ fragment: BrickFragment, at index: Int) {
      lock.withLock { fragments[index] = fragment }
    }

    func result() -> [BrickFragment] {
      lock.withLock {
        fragments.map { $0 ?? BrickFragment(vertices: "", faces: "") }
      }
    }
  }

  private static let cornerOffsets = [
    SIMD3<Int>(0, 0, 0), SIMD3<Int>(1, 0, 0),
    SIMD3<Int>(1, 1, 0), SIMD3<Int>(0, 1, 0),
    SIMD3<Int>(0, 0, 1), SIMD3<Int>(1, 0, 1),
    SIMD3<Int>(1, 1, 1), SIMD3<Int>(0, 1, 1)
  ]

  private static let edgeCorners = [
    (0, 1), (1, 2), (2, 3), (3, 0),
    (4, 5), (5, 6), (6, 7), (7, 4),
    (0, 4), (1, 5), (2, 6), (3, 7)
  ]

  @discardableResult
  static func extract(
    dataset: BORGVRDatasetProtocol,
    normalizedIsoValue: Double,
    outputURL requestedOutputURL: URL,
    normalize: Bool = false,
    logger: LoggerBase? = nil,
    cancellationToken: CancellationToken? = nil,
    progress: @escaping @Sendable (Double) -> Void = { _ in }
  ) throws -> Result {
    let extractionStart = Date()
    let outputURL = normalizedOutputURL(requestedOutputURL)
    let metadata = dataset.getMetadata()
    try validate(metadata: metadata)
    try cancellationToken?.checkCancellation()

    let level = metadata.levelMetadata[0]
    let size = level.size
    let brickCount = level.totalBricks
    let brickStride = metadata.brickSize - 2 * metadata.overlap
    let totalBrickCount = try checkedProduct(brickCount.x, brickCount.y, brickCount.z)
    let normalizedThreshold = min(1, max(0, normalizedIsoValue))
    let threshold = normalizedThreshold * Double(metadata.rangeMax)
    let spacing = SIMD3<Double>(
      Double(metadata.voxelSpacingX),
      Double(metadata.voxelSpacingY),
      Double(metadata.voxelSpacingZ)
    )
    let longestAxis = max(Double(size.x) * spacing.x, Double(size.y) * spacing.y,
                          Double(size.z) * spacing.z)
    let positionScale = normalize ? 2 / longestAxis : 1

    let fileManager = FileManager.default
    let directory = outputURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let temporaryStem = ".borgvr-isosurface-\(UUID().uuidString)"
    let temporaryDirectory = fileManager.temporaryDirectory
    let vertexURL = temporaryDirectory.appendingPathComponent(temporaryStem + "-vertices.tmp")
    let faceURL = temporaryDirectory.appendingPathComponent(temporaryStem + "-faces.tmp")
    let outputTemporaryURL = temporaryDirectory.appendingPathComponent(temporaryStem + ".obj.tmp")
    defer {
      try? FileManager.default.removeItem(at: vertexURL)
      try? FileManager.default.removeItem(at: faceURL)
      try? FileManager.default.removeItem(at: outputTemporaryURL)
    }

    logger?.info(
      "Extracting level-zero isosurface at normalized isovalue " +
      "\(normalizedThreshold) (raw \(threshold), dataset range " +
      "\(metadata.minValue)...\(metadata.maxValue) of 0...\(metadata.rangeMax)) from " +
      "\(size.x) x \(size.y) x \(size.z) voxels."
    )
    progress(0)

    let metalBackend: BorgVRMetalIsoSurfaceClassifier?
    if metadata.overlap > 0,
       ProcessInfo.processInfo.environment["BORGVR_DISABLE_METAL_ISOSURFACE"] != "1" {
      do {
        metalBackend = try BorgVRMetalIsoSurfaceClassifier()
        logger?.info("Using Metal to classify MC33 cells brick by brick.")
      } catch {
        metalBackend = nil
        logger?.warning(
          "Metal isosurface classification is unavailable; using the CPU: " +
          error.localizedDescription
        )
      }
    } else {
      metalBackend = nil
      if metadata.overlap == 0 {
        logger?.info("Using CPU MC33 extraction because the dataset has no brick overlap.")
      }
    }
    let metalBackendState = MetalBackendState(metalBackend, logger: logger)

    var vertexWriter = try BufferedTextWriter(url: vertexURL)
    var faceWriter = try BufferedTextWriter(url: faceURL)
    var nextVertexIndex = 1
    var triangleCount = 0
    var completedBricks = 0
    var lastReportedProgress = 0.0
    var meshGenerationTime = 0.0
    var textFormattingTime = 0.0
    var fragmentWritingTime = 0.0
    let context = ExtractionContext(
      dataset: dataset,
      metadata: metadata,
      threshold: threshold,
      volumeSize: size,
      spacing: spacing,
      cancellationToken: cancellationToken,
      metalBackend: metalBackendState
    )
    var jobs: [BrickJob] = []
    jobs.reserveCapacity(totalBrickCount)
    for brickZ in 0..<brickCount.z {
      for brickY in 0..<brickCount.y {
        for brickX in 0..<brickCount.x {
          let origin = SIMD3<Int>(
            brickX * brickStride,
            brickY * brickStride,
            brickZ * brickStride
          )
          let cellEnd = SIMD3<Int>(
            min(origin.x + brickStride, size.x - 1),
            min(origin.y + brickStride, size.y - 1),
            min(origin.z + brickStride, size.z - 1)
          )
          let hasCells = origin.x < cellEnd.x && origin.y < cellEnd.y && origin.z < cellEnd.z
          let brickIndex = level.prevBricks + brickX + brickY * brickCount.x + brickZ * brickCount.x * brickCount.y
          // Edits can create crossings in previously uniform bricks. Unknown
          // current bounds must be read, never culled using original-file ranges.
          let shouldProcess = hasCells && (
            metadata.overlap == 0 || (dataset.visibilityMetadata(index: brickIndex).map {
              brickMayIntersect(metadata: $0, threshold: threshold)
            } ?? true)
          )
          jobs.append(
            BrickJob(
              brickX: brickX,
              brickY: brickY,
              brickZ: brickZ,
              origin: origin,
              cellEnd: cellEnd,
              shouldProcess: shouldProcess
            )
          )
        }
      }
    }
    let workerCount = min(8, max(1, ProcessInfo.processInfo.activeProcessorCount))

    do {
      for batchStart in stride(from: 0, to: jobs.count, by: workerCount) {
        try cancellationToken?.checkCancellation()
        let batchEnd = min(batchStart + workerCount, jobs.count)
        let batch = Array(jobs[batchStart..<batchEnd])
        let meshStorage = MeshBatchStorage(count: batch.count)
        let meshGenerationStart = Date()
        DispatchQueue.concurrentPerform(iterations: batch.count) { index in
          do {
            let mesh = try extractBrick(batch[index], context: context)
            meshStorage.store(mesh, at: index)
          } catch {
            meshStorage.store(error: error)
          }
        }
        let meshes = try meshStorage.result()
        meshGenerationTime += Date().timeIntervalSince(meshGenerationStart)

        var baseIndices = Array(repeating: 0, count: meshes.count)
        var followingIndex = nextVertexIndex
        for index in meshes.indices {
          baseIndices[index] = followingIndex
          followingIndex += meshes[index].vertices.count
        }
        let fragmentStorage = FragmentBatchStorage(count: meshes.count)
        let textFormattingStart = Date()
        DispatchQueue.concurrentPerform(iterations: meshes.count) { index in
          fragmentStorage.store(
            format(meshes[index], baseIndex: baseIndices[index], positionScale: positionScale),
            at: index
          )
        }
        let fragments = fragmentStorage.result()
        textFormattingTime += Date().timeIntervalSince(textFormattingStart)

        let fragmentWritingStart = Date()
        for index in meshes.indices {
          try cancellationToken?.checkCancellation()
          try vertexWriter.append(fragments[index].vertices)
          try faceWriter.append(fragments[index].faces)
          nextVertexIndex += meshes[index].vertices.count
          triangleCount += meshes[index].triangles.count

          completedBricks += 1
          let currentProgress = 0.95 * Double(completedBricks) / Double(totalBrickCount)
          if currentProgress - lastReportedProgress >= 0.001 ||
              completedBricks == totalBrickCount {
            progress(currentProgress)
            lastReportedProgress = currentProgress
          }
        }
        fragmentWritingTime += Date().timeIntervalSince(fragmentWritingStart)
      }
      try cancellationToken?.checkCancellation()
      try vertexWriter.finish()
      try faceWriter.finish()
    } catch {
      try? vertexWriter.finish()
      try? faceWriter.finish()
      throw error
    }

    guard triangleCount > 0 else { throw Error.noSurface }
    progress(0.97)
    try writeOBJ(
      to: outputTemporaryURL,
      vertexURL: vertexURL,
      faceURL: faceURL,
      sourceDescription: metadata.datasetDescription,
      isoValue: threshold,
      normalize: normalize,
      cancellationToken: cancellationToken
    )
    try cancellationToken?.checkCancellation()
    progress(0.99)

    if fileManager.fileExists(atPath: outputURL.path) {
      _ = try fileManager.replaceItemAt(
        outputURL,
        withItemAt: outputTemporaryURL,
        backupItemName: nil,
        options: []
      )
    } else {
      try fileManager.moveItem(at: outputTemporaryURL, to: outputURL)
    }
    progress(1)
    let result = Result(
      outputURL: outputURL,
      vertexCount: nextVertexIndex - 1,
      triangleCount: triangleCount
    )
    logger?.info(
      "Isosurface extraction completed: \(result.vertexCount) vertices, " +
      "\(result.triangleCount) triangles in " +
      String(format: "%.3f", Date().timeIntervalSince(extractionStart)) +
      " seconds (\(metalBackendState.didUseMetal ? "Metal-assisted" : "CPU"))."
    )
    logger?.dev(
      String(
        format: "Isosurface phases: mesh %.3f s, OBJ formatting %.3f s, fragment writing %.3f s.",
        meshGenerationTime,
        textFormattingTime,
        fragmentWritingTime
      )
    )
    return result
  }

  private static func validate(metadata: BORGVRMetaData) throws {
    guard let level = metadata.levelMetadata.first,
          level.size.x >= 2, level.size.y >= 2, level.size.z >= 2 else {
      throw Error.invalidMetadata(
        String(localized: "level zero must contain at least two voxels per axis")
      )
    }
    guard metadata.componentCount > 0 else {
      throw Error.invalidMetadata(String(localized: "component count must be positive"))
    }
    guard [1, 2, 4].contains(metadata.bytesPerComponent) else {
      throw Error.unsupportedComponentSize(metadata.bytesPerComponent)
    }
    guard metadata.brickSize > 0,
          metadata.overlap >= 0,
          metadata.brickSize > 2 * metadata.overlap else {
      throw Error.invalidMetadata(
        String(localized: "brick size and overlap do not define a positive stride")
      )
    }
    let spacing = [metadata.voxelSpacingX, metadata.voxelSpacingY, metadata.voxelSpacingZ]
    guard spacing.allSatisfy({ $0.isFinite && $0 > 0 }) else {
      throw Error.invalidMetadata(String(localized: "voxel spacing must be finite and positive"))
    }
  }

  private static func normalizedOutputURL(_ url: URL) -> URL {
    url.pathExtension.lowercased() == "obj" ? url : url.appendingPathExtension("obj")
  }

  private static func brickMayIntersect(
    metadata: BrickMetadata,
    threshold: Double
  ) -> Bool {
    guard !metadata.componentRanges.isEmpty else { return true }
    let scalarMinimum = metadata.componentRanges.map(\.minValue).min() ?? metadata.minValue
    let scalarMaximum = metadata.componentRanges.map(\.maxValue).min() ?? metadata.maxValue
    return threshold >= Double(scalarMinimum) && threshold <= Double(scalarMaximum)
  }

  private static func extractBrick(
    _ job: BrickJob,
    context: ExtractionContext
  ) throws -> BrickMesh {
    guard job.shouldProcess else { return BrickMesh() }
    if let metalBackend = context.metalBackend.current() {
      do {
        let mesh = try extractBrickWithMetal(job, context: context, backend: metalBackend)
        context.metalBackend.recordSuccess()
        return mesh
      } catch {
        context.metalBackend.disable(after: error)
      }
    }
    return try extractBrickWithCPU(job, context: context)
  }

  private static func extractBrickWithCPU(
    _ job: BrickJob,
    context: ExtractionContext
  ) throws -> BrickMesh {
    let reader = BrickReader(
      dataset: context.dataset,
      metadata: context.metadata,
      cancellationToken: context.cancellationToken
    )
    let brick = try reader.brick(x: job.brickX, y: job.brickY, z: job.brickZ)
    var mesh = BrickMesh()

    for z in job.origin.z..<job.cellEnd.z {
      try context.cancellationToken?.checkCancellation()
      for y in job.origin.y..<job.cellEnd.y {
        for x in job.origin.x..<job.cellEnd.x {
          let cellOrigin = SIMD3<Int>(x, y, z)
          let values = try cornerValues(
            cellOrigin: cellOrigin,
            brickOrigin: job.origin,
            brick: brick,
            reader: reader,
            overlap: context.metadata.overlap
          )
          let minimum = values.min() ?? context.threshold
          let maximum = values.max() ?? context.threshold
          guard minimum <= context.threshold,
                maximum >= context.threshold,
                minimum != maximum else { continue }

          let cellTriangles = BorgVRMarchingCubes33.triangles(
            values: values,
            threshold: context.threshold
          )
          try appendCell(
            origin: cellOrigin,
            values: values,
            triangles: cellTriangles,
            reader: reader,
            brickOrigin: job.origin,
            brick: brick,
            context: context,
            to: &mesh
          )
        }
      }
    }
    return mesh
  }

  private static func extractBrickWithMetal(
    _ job: BrickJob,
    context: ExtractionContext,
    backend: BorgVRMetalIsoSurfaceClassifier
  ) throws -> BrickMesh {
    try context.cancellationToken?.checkCancellation()
    let reader = BrickReader(
      dataset: context.dataset,
      metadata: context.metadata,
      cancellationToken: context.cancellationToken
    )
    let brick = try reader.brick(x: job.brickX, y: job.brickY, z: job.brickZ)
    let cellDimensions = SIMD3<Int>(
      job.cellEnd.x - job.origin.x,
      job.cellEnd.y - job.origin.y,
      job.cellEnd.z - job.origin.z
    )
    let classification = try backend.classify(
      brickBytes: UnsafeRawPointer(brick.pointer),
      brickSize: context.metadata.brickSize,
      componentCount: context.metadata.componentCount,
      bytesPerComponent: context.metadata.bytesPerComponent,
      overlap: context.metadata.overlap,
      cellDimensions: cellDimensions,
      threshold: context.threshold
    )
    try context.cancellationToken?.checkCancellation()

    var mesh = BrickMesh()
    for localZ in 0..<cellDimensions.z {
      try context.cancellationToken?.checkCancellation()
      for localY in 0..<cellDimensions.y {
        for localX in 0..<cellDimensions.x {
          let cellIndex = localX + localY * cellDimensions.x +
            localZ * cellDimensions.x * cellDimensions.y
          let triangleCount = classification.triangleCount(cellIndex: cellIndex)
          guard triangleCount > 0 else { continue }
          let cellOrigin = SIMD3<Int>(
            job.origin.x + localX,
            job.origin.y + localY,
            job.origin.z + localZ
          )
          let values = try cornerValues(
            cellOrigin: cellOrigin,
            brickOrigin: job.origin,
            brick: brick,
            reader: reader,
            overlap: context.metadata.overlap
          )
          var triangles: [BorgVRMarchingCubes33.Triangle] = []
          triangles.reserveCapacity(triangleCount)
          for triangleIndex in 0..<triangleCount {
            let packed = classification.packedTriangle(
              cellIndex: cellIndex,
              triangleIndex: triangleIndex
            )
            triangles.append(
              BorgVRMarchingCubes33.Triangle(
                firstEdge: Int(packed & 0x0F),
                secondEdge: Int((packed >> 4) & 0x0F),
                thirdEdge: Int((packed >> 8) & 0x0F)
              )
            )
          }
          try appendCell(
            origin: cellOrigin,
            values: values,
            triangles: triangles,
            reader: reader,
            brickOrigin: job.origin,
            brick: brick,
            context: context,
            to: &mesh
          )
        }
      }
    }
    return mesh
  }

  private static func appendCell(
    origin: SIMD3<Int>,
    values: [Double],
    triangles: [BorgVRMarchingCubes33.Triangle],
    reader: BrickReader,
    brickOrigin: SIMD3<Int>,
    brick: LoadedBrick,
    context: ExtractionContext,
    to mesh: inout BrickMesh
  ) throws {
    guard !triangles.isEmpty else { return }
    let gradients = try cornerOffsets.map { offset in
      try reader.gradient(at: origin &+ offset, brickOrigin: brickOrigin, brick: brick)
    }
    var used = Array(repeating: false, count: 13)
    for triangle in triangles {
      guard triangle.firstEdge < used.count,
            triangle.secondEdge < used.count,
            triangle.thirdEdge < used.count else { continue }
      used[triangle.firstEdge] = true
      used[triangle.secondEdge] = true
      used[triangle.thirdEdge] = true
    }
    let usedEdges = used.indices.filter { used[$0] }
    let rawVertices = usedEdges.map {
      vertex(
        edge: $0,
        cellOrigin: origin,
        values: values,
        gradients: gradients,
        threshold: context.threshold,
        volumeSize: context.volumeSize,
        spacing: context.spacing
      )
    }
    let cellBaseIndex = mesh.vertices.count
    var localIndexByEdge = Array(repeating: -1, count: 13)
    for (index, edge) in usedEdges.enumerated() {
      localIndexByEdge[edge] = index
    }

    var validTriangles: [SIMD3<Int>] = []
    validTriangles.reserveCapacity(triangles.count)
    var fallbackNormal: SIMD3<Double>?
    for triangle in triangles {
      guard triangle.firstEdge < localIndexByEdge.count,
            triangle.secondEdge < localIndexByEdge.count,
            triangle.thirdEdge < localIndexByEdge.count else { continue }
      var indices = [
        localIndexByEdge[triangle.firstEdge],
        localIndexByEdge[triangle.secondEdge],
        localIndexByEdge[triangle.thirdEdge]
      ]
      guard indices.allSatisfy({ $0 >= 0 }) else { continue }
      let a = rawVertices[indices[0]].position
      let b = rawVertices[indices[1]].position
      let c = rawVertices[indices[2]].position
      let geometricNormal = simd_cross(b - a, c - a)
      let lengthSquared = simd_length_squared(geometricNormal)
      guard lengthSquared.isFinite, lengthSquared > 0 else { continue }
      let normalizedGeometricNormal = simd_normalize(geometricNormal)
      let expectedNormal = -(rawVertices[indices[0]].normal +
        rawVertices[indices[1]].normal + rawVertices[indices[2]].normal)
      if simd_dot(geometricNormal, expectedNormal) < 0 {
        indices.swapAt(1, 2)
        fallbackNormal = fallbackNormal ?? -normalizedGeometricNormal
      } else {
        fallbackNormal = fallbackNormal ?? normalizedGeometricNormal
      }
      validTriangles.append(
        SIMD3<Int>(
          cellBaseIndex + indices[0],
          cellBaseIndex + indices[1],
          cellBaseIndex + indices[2]
        )
      )
    }
    guard !validTriangles.isEmpty else { return }

    let fallback = fallbackNormal ?? SIMD3<Double>(0, 0, 1)
    mesh.vertices.append(
      contentsOf: rawVertices.map {
        Vertex(position: $0.position, normal: normalized(-$0.normal, fallback: fallback))
      }
    )
    mesh.triangles.append(contentsOf: validTriangles)
  }

  private static func format(_ mesh: BrickMesh, baseIndex: Int, positionScale: Double) -> BrickFragment {
    var vertices = ""
    vertices.reserveCapacity(mesh.vertices.count * 80)
    for vertex in mesh.vertices {
      vertices.append(objVertex(vertex.position * positionScale))
      vertices.append(objNormal(vertex.normal))
    }

    var faces = ""
    faces.reserveCapacity(mesh.triangles.count * 50)
    for triangle in mesh.triangles {
      let first = baseIndex + triangle.x
      let second = baseIndex + triangle.y
      let third = baseIndex + triangle.z
      faces.append("f \(first)//\(first) \(second)//\(second) \(third)//\(third)\n")
    }
    return BrickFragment(vertices: vertices, faces: faces)
  }

  private static func cornerValues(
    cellOrigin: SIMD3<Int>,
    brickOrigin: SIMD3<Int>,
    brick: LoadedBrick,
    reader: BrickReader,
    overlap: Int
  ) throws -> [Double] {
    if overlap > 0 {
      return cornerOffsets.map { offset in
        let local = SIMD3<Int>(
          cellOrigin.x + offset.x - brickOrigin.x + overlap,
          cellOrigin.y + offset.y - brickOrigin.y + overlap,
          cellOrigin.z + offset.z - brickOrigin.z + overlap
        )
        return brick.scalar(x: local.x, y: local.y, z: local.z)
      }
    }
    return try cornerOffsets.map { offset in
      let position = SIMD3<Int>(
        cellOrigin.x + offset.x,
        cellOrigin.y + offset.y,
        cellOrigin.z + offset.z
      )
      return try reader.scalar(x: position.x, y: position.y, z: position.z)
    }
  }

  private static func vertex(
    edge: Int,
    cellOrigin: SIMD3<Int>,
    values: [Double],
    gradients: [SIMD3<Double>],
    threshold: Double,
    volumeSize: Vec3<Int>,
    spacing: SIMD3<Double>
  ) -> Vertex {
    if edge == 12 {
      let local = SIMD3<Double>(repeating: 0.5)
      let voxel = SIMD3<Double>(
        Double(cellOrigin.x) + local.x,
        Double(cellOrigin.y) + local.y,
        Double(cellOrigin.z) + local.z
      )
      let center = SIMD3<Double>(
        Double(volumeSize.x) / 2,
        Double(volumeSize.y) / 2,
        Double(volumeSize.z) / 2
      )
      return Vertex(
        position: (voxel + SIMD3<Double>(repeating: 0.5) - center) * spacing,
        normal: gradients.reduce(.zero, +) / 8
      )
    }
    let corners = edgeCorners[edge]
    let aOffset = cornerOffsets[corners.0]
    let bOffset = cornerOffsets[corners.1]
    let aValue = values[corners.0]
    let bValue = values[corners.1]
    let denominator = bValue - aValue
    let interpolation = abs(denominator) > Double.ulpOfOne
      ? min(1, max(0, (threshold - aValue) / denominator))
      : 0.5
    let local = SIMD3<Double>(
      Double(aOffset.x) + Double(bOffset.x - aOffset.x) * interpolation,
      Double(aOffset.y) + Double(bOffset.y - aOffset.y) * interpolation,
      Double(aOffset.z) + Double(bOffset.z - aOffset.z) * interpolation
    )
    let voxel = SIMD3<Double>(
      Double(cellOrigin.x) + local.x,
      Double(cellOrigin.y) + local.y,
      Double(cellOrigin.z) + local.z
    )
    let center = SIMD3<Double>(
      Double(volumeSize.x) / 2,
      Double(volumeSize.y) / 2,
      Double(volumeSize.z) / 2
    )
    let position = (voxel + SIMD3<Double>(repeating: 0.5) - center) * spacing
    return Vertex(
      position: position,
      normal: simd_mix(gradients[corners.0], gradients[corners.1],
                       SIMD3<Double>(repeating: interpolation))
    )
  }

  private static func normalized(
    _ value: SIMD3<Double>,
    fallback: SIMD3<Double>
  ) -> SIMD3<Double> {
    let lengthSquared = simd_length_squared(value)
    return lengthSquared > 0 && lengthSquared.isFinite ? simd_normalize(value) : fallback
  }

  private static func objVertex(_ position: SIMD3<Double>) -> String {
    "v \(Float(position.x)) \(Float(position.y)) \(Float(position.z))\n"
  }

  private static func objNormal(_ normal: SIMD3<Double>) -> String {
    "vn \(Float(normal.x)) \(Float(normal.y)) \(Float(normal.z))\n"
  }

  private static func writeOBJ(
    to outputURL: URL,
    vertexURL: URL,
    faceURL: URL,
    sourceDescription: String,
    isoValue: Double,
    normalize: Bool,
    cancellationToken: CancellationToken?
  ) throws {
    _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    let output = try FileHandle(forWritingTo: outputURL)
    defer { try? output.close() }
    let header = """
    # BorgVR Marching Cubes isosurface
    # Source: \(sourceDescription.replacingOccurrences(of: "\n", with: " "))
    # Raw isovalue: \(isoValue)
    # Coordinates are centered on the source volume.
    # \(normalize ? "The longest source-volume axis is normalized to [-1, 1]; coordinates are unitless." : "Coordinates are expressed in meters.")
    o BorgVR_Isosurface

    """
    try output.write(contentsOf: Data(header.utf8))
    try appendFile(vertexURL, to: output, cancellationToken: cancellationToken)
    try appendFile(faceURL, to: output, cancellationToken: cancellationToken)
  }

  private static func appendFile(
    _ sourceURL: URL,
    to output: FileHandle,
    cancellationToken: CancellationToken?
  ) throws {
    let source = try FileHandle(forReadingFrom: sourceURL)
    defer { try? source.close() }
    while let data = try source.read(upToCount: 1024 * 1024), !data.isEmpty {
      try cancellationToken?.checkCancellation()
      try output.write(contentsOf: data)
    }
  }

  private static func checkedProduct(_ a: Int, _ b: Int, _ c: Int) throws -> Int {
    let (ab, firstOverflow) = a.multipliedReportingOverflow(by: b)
    let (abc, secondOverflow) = ab.multipliedReportingOverflow(by: c)
    guard !firstOverflow, !secondOverflow, abc > 0 else { throw Error.outputSizeOverflow }
    return abc
  }

  private final class LoadedBrick {
    let pointer: UnsafeMutablePointer<UInt8>
    let brickSize: Int
    let componentCount: Int
    let bytesPerComponent: Int

    init(dataset: BORGVRDatasetProtocol, metadata: BORGVRMetaData, index: Int) throws {
      brickSize = metadata.brickSize
      componentCount = metadata.componentCount
      bytesPerComponent = metadata.bytesPerComponent
      let allocatedPointer = dataset.allocateBrickBuffer()
      do {
        try dataset.getBrick(index: index, outputBuffer: allocatedPointer)
      } catch {
        allocatedPointer.deallocate()
        throw error
      }
      pointer = allocatedPointer
    }

    deinit {
      pointer.deallocate()
    }

    func scalar(x: Int, y: Int, z: Int) -> Double {
      let voxelIndex = (z * brickSize * brickSize + y * brickSize + x) * componentCount
      var minimum = UInt64.max
      for component in 0..<componentCount {
        let byteOffset = (voxelIndex + component) * bytesPerComponent
        let value: UInt64
        switch bytesPerComponent {
          case 1:
            value = UInt64(pointer[byteOffset])
          case 2:
            value = UInt64(pointer[byteOffset]) |
              (UInt64(pointer[byteOffset + 1]) << 8)
          default:
            value = UInt64(pointer[byteOffset]) |
              (UInt64(pointer[byteOffset + 1]) << 8) |
              (UInt64(pointer[byteOffset + 2]) << 16) |
              (UInt64(pointer[byteOffset + 3]) << 24)
        }
        minimum = min(minimum, value)
      }
      return Double(minimum)
    }
  }

  private final class BrickReader {
    private let dataset: BORGVRDatasetProtocol
    private let metadata: BORGVRMetaData
    private let cancellationToken: CancellationToken?
    private let level: LevelMetadata
    private let stride: Int
    private var cache: [Int: LoadedBrick] = [:]
    private var accessOrder: [Int] = []
    private var gradients: [SIMD3<Int>: SIMD3<Double>] = [:]
    private let maximumCachedBrickCount = 16

    init(
      dataset: BORGVRDatasetProtocol,
      metadata: BORGVRMetaData,
      cancellationToken: CancellationToken?
    ) {
      self.dataset = dataset
      self.metadata = metadata
      self.cancellationToken = cancellationToken
      self.level = metadata.levelMetadata[0]
      self.stride = metadata.brickSize - 2 * metadata.overlap
    }

    func gradient(at position: SIMD3<Int>, brickOrigin: SIMD3<Int>,
                  brick: LoadedBrick) throws -> SIMD3<Double> {
      if let cached = gradients[position] { return cached }
      let size = SIMD3(level.size.x, level.size.y, level.size.z)
      let spacing = SIMD3(Double(metadata.voxelSpacingX), Double(metadata.voxelSpacingY),
                          Double(metadata.voxelSpacingZ))
      var gradient = SIMD3<Double>.zero
      for axis in 0..<3 {
        var before = position
        var after = position
        before[axis] = max(0, position[axis] - 1)
        after[axis] = min(size[axis] - 1, position[axis] + 1)
        let lower = try scalar(at: before, brickOrigin: brickOrigin, brick: brick)
        let upper = try scalar(at: after, brickOrigin: brickOrigin, brick: brick)
        gradient[axis] = (upper - lower) / (Double(after[axis] - before[axis]) * spacing[axis])
      }
      gradients[position] = gradient
      return gradient
    }

    private func scalar(at position: SIMD3<Int>, brickOrigin: SIMD3<Int>,
                        brick: LoadedBrick) throws -> Double {
      let local = position &- brickOrigin &+ SIMD3(repeating: metadata.overlap)
      if local.x >= 0, local.y >= 0, local.z >= 0,
         local.x < metadata.brickSize, local.y < metadata.brickSize, local.z < metadata.brickSize {
        return brick.scalar(x: local.x, y: local.y, z: local.z)
      }
      // A narrow or absent overlap may not contain the central-difference neighbors.
      return try scalar(x: position.x, y: position.y, z: position.z)
    }

    func scalar(x: Int, y: Int, z: Int) throws -> Double {
      let brickX = min(x / stride, level.totalBricks.x - 1)
      let brickY = min(y / stride, level.totalBricks.y - 1)
      let brickZ = min(z / stride, level.totalBricks.z - 1)
      let brick = try brick(x: brickX, y: brickY, z: brickZ)
      return brick.scalar(
        x: x - brickX * stride + metadata.overlap,
        y: y - brickY * stride + metadata.overlap,
        z: z - brickZ * stride + metadata.overlap
      )
    }

    func brick(x: Int, y: Int, z: Int) throws -> LoadedBrick {
      let index = level.prevBricks + x + y * level.totalBricks.x +
        z * level.totalBricks.x * level.totalBricks.y
      if let cached = cache[index] {
        touch(index)
        return cached
      }

      let loaded: LoadedBrick
      while true {
        try cancellationToken?.checkCancellation()
        do {
          loaded = try LoadedBrick(dataset: dataset, metadata: metadata, index: index)
          break
        } catch BORGVRDataError.brickNotYetAvailable {
          Thread.sleep(forTimeInterval: 0.05)
        }
      }
      cache[index] = loaded
      touch(index)
      while accessOrder.count > maximumCachedBrickCount {
        cache.removeValue(forKey: accessOrder.removeFirst())
      }
      return loaded
    }

    private func touch(_ index: Int) {
      accessOrder.removeAll { $0 == index }
      accessOrder.append(index)
    }
  }

  private struct BufferedTextWriter {
    private static let flushThreshold = 1024 * 1024
    private let handle: FileHandle
    private var buffer = String()
    private var finished = false

    init(url: URL) throws {
      _ = FileManager.default.createFile(atPath: url.path, contents: nil)
      handle = try FileHandle(forWritingTo: url)
      buffer.reserveCapacity(Self.flushThreshold)
    }

    mutating func append(_ text: String) throws {
      buffer.append(text)
      if buffer.utf8.count >= Self.flushThreshold {
        try flush()
      }
    }

    mutating func finish() throws {
      guard !finished else { return }
      try flush()
      try handle.close()
      finished = true
    }

    private mutating func flush() throws {
      guard !buffer.isEmpty else { return }
      try handle.write(contentsOf: Data(buffer.utf8))
      buffer.removeAll(keepingCapacity: true)
    }
  }
}
