import Foundation

private struct IsoSurfaceEditFailure: Error { let message: String }

private final class UnknownIsoSurfaceBounds: BORGVRDatasetProtocol {
  let source: BORGVRDatasetProtocol
  init(_ source: BORGVRDatasetProtocol) { self.source = source }
  func getMetadata() -> BORGVRMetaData { source.getMetadata() }
  func allocateBrickBuffer() -> UnsafeMutablePointer<UInt8> { source.allocateBrickBuffer() }
  func newRequest() { source.newRequest() }
  func visibilityMetadata(index: Int) -> BrickMetadata? { nil }
  func getBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    try source.getBrick(index: index, outputBuffer: outputBuffer)
  }
  func getFirstBrick(outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    try source.getFirstBrick(outputBuffer: outputBuffer)
  }
}

func runIsoSurfaceEditTests() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-isosurface-edits-\(UUID())")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let previousBackend = ProcessInfo.processInfo.environment["BORGVR_DISABLE_METAL_ISOSURFACE"]
  defer {
    if let previousBackend { setenv("BORGVR_DISABLE_METAL_ISOSURFACE", previousBackend, 1) }
    else { unsetenv("BORGVR_DISABLE_METAL_ISOSURFACE") }
  }
  func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw IsoSurfaceEditFailure(message: message) }
  }
  let size = Vec3<Int>(x: 12, y: 10, z: 8)
  let spacing = Vec3<Float>(x: 0.25, y: 0.5, z: 1)
  let erase = BorgVRVolumeBrushSample(center: SIMD3(1.5, 2.5, 4), radius: 1.2)
  let restore = BorgVRVolumeBrushSample(center: erase.center, radius: 0.75)
  func inside(_ sample: BorgVRVolumeBrushSample, _ position: SIMD3<Double>) -> Bool {
    let delta = position - sample.center
    return delta.x * delta.x + delta.y * delta.y + delta.z * delta.z <= sample.radius * sample.radius
  }
  for width in [1, 2] {
    let solid: UInt64 = width == 1 ? 200 : 50000
    let second: UInt64 = width == 1 ? 255 : 65535
    func voxels(erased: Bool, restored: Bool) -> Data {
      var data = Data()
      for z in 0..<size.z { for y in 0..<size.y { for x in 0..<size.x {
        let position = SIMD3(Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5) * SIMD3(0.25, 0.5, 1)
        let removed = erased && inside(erase, position) && !(restored && inside(restore, position))
        for value in [solid, second] {
          for byte in 0..<width { data.append(removed ? 0 : UInt8(truncatingIfNeeded: value >> (byte * 8))) }
        }
      } } }
      return data
    }
    func volume(_ data: Data, name: String) throws -> BORGVRFileData {
      let rawURL = directory.appendingPathComponent(name + ".raw")
      let dataURL = directory.appendingPathComponent(name + ".data")
      try data.write(to: rawURL)
      let accessor = try RawFileAccessor(filename: rawURL.path, size: size, bytesPerComponent: width,
        componentCount: 2, voxelSpacing: spacing)
      try BrickedVolumeReorganizer(inputVolume: accessor, brickSize: 8, overlap: 2, extensionStrategy: .clamp)
        .reorganize(to: dataURL.path, datasetDescription: name, metaDescription: "")
      return try BORGVRFileData(filename: dataURL.path)
    }
    let original = try volume(voxels(erased: false, restored: false), name: "original-\(width)")
    try require(original.getMetadata().brickMetadata.allSatisfy { $0.minValue > Int(original.getMetadata().rangeMax) / 2 },
      "Fixture must create surfaces inside bricks that originally did not intersect the isovalue")
    let edited = try BorgVREditableVolumeData(source: original,
      directory: directory.appendingPathComponent("sidecar-\(width)"), logger: nil)
    defer {
      let closed = DispatchSemaphore(value: 0)
      edited.shutdown { _ in closed.signal() }
      _ = closed.wait(timeout: .now() + 10)
    }
    func apply(_ sample: BorgVRVolumeBrushSample, mode: BorgVRVolumeBrushMode) throws {
      let done = DispatchSemaphore(value: 0)
      let result = IsoSurfaceEditCompletion()
      edited.brush([sample], mode: mode) { error in
        result.lock.withLock { result.error = error }; done.signal()
      }
      try require(done.wait(timeout: .now() + 10) == .success, "Brush did not finish before extraction")
      if let error = result.lock.withLock({ result.error }) { throw error }
    }
    func mesh(_ dataset: BORGVRDatasetProtocol, name: String) throws -> [Substring] {
      let url = directory.appendingPathComponent(name + ".obj")
      let result = try BorgVRIsoSurfaceExtractor.extract(dataset: dataset, normalizedIsoValue: 0.5, outputURL: url)
      try require(result.triangleCount > 0, "Edited cavity did not produce any triangles")
      return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").filter {
        $0.hasPrefix("v ") || $0.hasPrefix("vn ") || $0.hasPrefix("f ")
      }
    }
    try apply(erase, mode: .erase)
    for restored in [false, true] {
      if restored { try apply(restore, mode: .restore) }
      let reference = try volume(voxels(erased: true, restored: restored), name: "reference-\(width)-\(restored)")
      for cpu in [true, false] {
        setenv("BORGVR_DISABLE_METAL_ISOSURFACE", cpu ? "1" : "0", 1)
        let suffix = "\(width)-\(restored)-\(cpu)"
        let expected = try mesh(reference, name: "expected-" + suffix)
        let actual = try mesh(edited, name: "edited-" + suffix)
        try require(actual == expected, "Edited isosurface omitted or changed cells at brick/halo boundaries: " + suffix)
        let unknown = try mesh(UnknownIsoSurfaceBounds(edited), name: "unknown-" + suffix)
        try require(unknown == expected, "Unknown current brick ranges were treated as empty: " + suffix)
      }
    }
    try apply(.init(center: erase.center, radius: 100), mode: .restore)
    do {
      _ = try mesh(edited, name: "fully-restored-\(width)")
      throw IsoSurfaceEditFailure(message: "Full restore retained an extracted edit surface")
    } catch BorgVRIsoSurfaceExtractor.Error.noSurface {}
  }
  print("Edited isosurface CPU/Metal and brick-boundary tests passed")
}

private final class IsoSurfaceEditCompletion: @unchecked Sendable {
  let lock = NSLock()
  var error: Error?
}
