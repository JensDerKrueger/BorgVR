/*
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of Duisburg-
 Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of this
 software and associated documentation files (the "Software"), to deal in the Software
 without restriction, including without limitation the rights to use, copy, modify,
 merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 permit persons to whom the Software is furnished to do so, subject to the following
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
import Foundation

/// Reconstructs one BorgVR LoD as a flat, uncompressed, inline NRRD volume.
enum BORGVRVolumeExporter {
  struct Result {
    let outputURL: URL
    let level: Int
    let size: Vec3<Int>
    let voxelSpacing: Vec3<Float>
    let componentCount: Int
    let bytesPerComponent: Int
  }

  enum Error: Swift.Error, LocalizedError {
    case invalidLevel(requested: Int, available: Int)
    case unsupportedComponentSize(Int)
    case unsupportedOutputExtension(String)
    case invalidMetadata(String)
    case outputSizeOverflow
    case inputEqualsOutput

    var errorDescription: String? {
      switch self {
        case .invalidLevel(let requested, let available):
          return "LoD \(requested) is unavailable; valid levels are 0 through \(max(0, available - 1))."
        case .unsupportedComponentSize(let size):
          return "Cannot export components with \(size) byte(s)."
        case .unsupportedOutputExtension(let pathExtension):
          return "The export file must use the .nrrd extension, not .\(pathExtension)."
        case .invalidMetadata(let reason):
          return "The BorgVR dataset metadata is invalid: \(reason)."
        case .outputSizeOverflow:
          return "The exported volume is too large for this system."
        case .inputEqualsOutput:
          return "The export file must not replace the BorgVR source dataset."
      }
    }
  }

  static func export(
    inputURL: URL,
    outputURL requestedOutputURL: URL,
    level: Int,
    logger: LoggerBase? = nil
  ) throws -> Result {
    let outputURL = try normalizedOutputURL(requestedOutputURL)
    guard inputURL.standardizedFileURL != outputURL.standardizedFileURL else {
      throw Error.inputEqualsOutput
    }

    let source = try BORGVRFileData(filename: inputURL.path)
    let metadata = source.getMetadata()
    guard level >= 0, level < metadata.levelMetadata.count else {
      throw Error.invalidLevel(requested: level, available: metadata.levelMetadata.count)
    }
    guard metadata.brickSize > 0,
          metadata.overlap >= 0,
          metadata.brickSize > 2 * metadata.overlap else {
      throw Error.invalidMetadata("brick size and overlap do not define a positive brick stride")
    }
    guard metadata.componentCount > 0 else {
      throw Error.invalidMetadata("component count must be positive")
    }

    let levelMetadata = metadata.levelMetadata[level]
    let size = levelMetadata.size
    guard size.x > 0, size.y > 0, size.z > 0 else {
      throw Error.invalidMetadata("LoD dimensions must be positive")
    }

    let scale = Float(pow(2.0, Double(level)))
    guard scale.isFinite else { throw Error.invalidMetadata("LoD scale is not finite") }
    let voxelSpacing = Vec3<Float>(
      x: metadata.voxelSpacingX * scale,
      y: metadata.voxelSpacingY * scale,
      z: metadata.voxelSpacingZ * scale
    )
    guard voxelSpacing.x.isFinite, voxelSpacing.x > 0,
          voxelSpacing.y.isFinite, voxelSpacing.y > 0,
          voxelSpacing.z.isFinite, voxelSpacing.z > 0 else {
      throw Error.invalidMetadata("voxel spacing must be finite and positive")
    }
    let header = try nrrdHeader(
      size: size,
      voxelSpacing: voxelSpacing,
      componentCount: metadata.componentCount,
      bytesPerComponent: metadata.bytesPerComponent,
      level: level
    )
    let voxelByteSize = try checkedProduct(
      [metadata.componentCount, metadata.bytesPerComponent]
    )
    let payloadByteCount = try checkedProduct(
      [size.x, size.y, size.z, voxelByteSize]
    )
    let (fileByteCount, fileSizeOverflow) = header.count.addingReportingOverflow(payloadByteCount)
    guard !fileSizeOverflow else { throw Error.outputSizeOverflow }

    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let temporaryURL = outputURL.deletingLastPathComponent()
      .appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID().uuidString).tmp")
    try? fileManager.removeItem(at: temporaryURL)

    logger?.info(
      "Exporting LoD \(level) as \(size.x) x \(size.y) x \(size.z) uncompressed NRRD volume."
    )

    do {
      let target = try MemoryMappedFile(filename: temporaryURL.path, size: Int64(fileByteCount))
      do {
        header.withUnsafeBytes { bytes in
          if let baseAddress = bytes.baseAddress {
            memcpy(target.mappedMemory, baseAddress, header.count)
          }
        }

        let brickSize = metadata.brickSize
        let overlap = metadata.overlap
        let brickStride = brickSize - 2 * overlap
        let brickBuffer = source.allocateBrickBuffer()
        defer { brickBuffer.deallocate() }
        let payloadBase = target.mappedMemory.advanced(by: header.count)
        let brickCount = levelMetadata.totalBricks
        let totalBricks = try checkedProduct([brickCount.x, brickCount.y, brickCount.z])
        var completedBricks = 0

        for brickZ in 0..<brickCount.z {
          let destinationZ = brickZ * brickStride
          let copyDepth = min(brickStride, size.z - destinationZ)
          for brickY in 0..<brickCount.y {
            let destinationY = brickY * brickStride
            let copyHeight = min(brickStride, size.y - destinationY)
            for brickX in 0..<brickCount.x {
              let destinationX = brickX * brickStride
              let copyWidth = min(brickStride, size.x - destinationX)
              try source.getBrick(
                level: level,
                x: brickX,
                y: brickY,
                z: brickZ,
                outputBuffer: brickBuffer
              )

              for localZ in 0..<copyDepth {
                for localY in 0..<copyHeight {
                  let sourceVoxel =
                    ((localZ + overlap) * brickSize * brickSize)
                    + ((localY + overlap) * brickSize)
                    + overlap
                  let destinationVoxel =
                    ((destinationZ + localZ) * size.y * size.x)
                    + ((destinationY + localY) * size.x)
                    + destinationX
                  memcpy(
                    payloadBase.advanced(by: destinationVoxel * voxelByteSize),
                    brickBuffer.advanced(by: sourceVoxel * voxelByteSize),
                    copyWidth * voxelByteSize
                  )
                }
              }

              completedBricks += 1
              logger?.progress(
                "Exporting LoD \(level)",
                Double(completedBricks) / Double(totalBricks)
              )
            }
          }
        }
        try target.close()
      } catch {
        try? target.close()
        throw error
      }

      if fileManager.fileExists(atPath: outputURL.path) {
        try fileManager.removeItem(at: outputURL)
      }
      try fileManager.moveItem(at: temporaryURL, to: outputURL)
    } catch {
      try? fileManager.removeItem(at: temporaryURL)
      throw error
    }

    logger?.progress("Exporting LoD \(level)", 1)
    logger?.info("Export completed: \(outputURL.path)")
    return Result(
      outputURL: outputURL,
      level: level,
      size: size,
      voxelSpacing: voxelSpacing,
      componentCount: metadata.componentCount,
      bytesPerComponent: metadata.bytesPerComponent
    )
  }

  private static func normalizedOutputURL(_ url: URL) throws -> URL {
    if url.pathExtension.isEmpty {
      return url.appendingPathExtension("nrrd")
    }
    guard url.pathExtension.lowercased() == "nrrd" else {
      throw Error.unsupportedOutputExtension(url.pathExtension)
    }
    return url
  }

  private static func nrrdHeader(
    size: Vec3<Int>,
    voxelSpacing: Vec3<Float>,
    componentCount: Int,
    bytesPerComponent: Int,
    level: Int
  ) throws -> Data {
    let type: String
    switch bytesPerComponent {
      case 1: type = "uint8"
      case 2: type = "uint16"
      case 4: type = "uint32"
      default: throw Error.unsupportedComponentSize(bytesPerComponent)
    }

    let xSpacing = format(voxelSpacing.x)
    let ySpacing = format(voxelSpacing.y)
    let zSpacing = format(voxelSpacing.z)
    let dimensionalFields: String
    if componentCount == 1 {
      dimensionalFields = """
      dimension: 3
      sizes: \(size.x) \(size.y) \(size.z)
      spacings: \(xSpacing) \(ySpacing) \(zSpacing)
      kinds: domain domain domain
      """
    } else {
      dimensionalFields = """
      dimension: 4
      sizes: \(componentCount) \(size.x) \(size.y) \(size.z)
      spacings: nan \(xSpacing) \(ySpacing) \(zSpacing)
      kinds: vector domain domain domain
      """
    }

    let header = """
    NRRD0005
    # Exported by BorgVR from LoD \(level)
    type: \(type)
    \(dimensionalFields)
    endian: little
    encoding: raw
    """ + "\n\n"
    return Data(header.utf8)
  }

  private static func format(_ value: Float) -> String {
    String(format: "%.9g", locale: Locale(identifier: "en_US_POSIX"), Double(value))
  }

  private static func checkedProduct(_ factors: [Int]) throws -> Int {
    var result = 1
    for factor in factors {
      guard factor >= 0 else { throw Error.outputSizeOverflow }
      let (product, overflow) = result.multipliedReportingOverflow(by: factor)
      guard !overflow else { throw Error.outputSizeOverflow }
      result = product
    }
    return result
  }
}
