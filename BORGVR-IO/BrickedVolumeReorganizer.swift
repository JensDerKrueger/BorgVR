import Foundation
import Compression
import os

/**
 Strategies for handling voxels when extending volume boundaries.
 */
public enum ExtensionStrategy {
  /// Extend by filling missing voxels with zeroes.
  case fillZeroes
  /// Extend by clamping to the nearest valid voxel.
  case clamp
  /// Extend by cycling through the data.
  case repeatValue
}

/**
 The core class responsible for reorganizing a monolithic 3D volume into a bricked hierarchy.
 It partitions the volume into overlapping bricks and then creates a downsampled version (which is also bricked).
 The process continues until the dataset fits into a single brick.
 */
public class BrickedVolumeReorganizer {

  // MARK: - Properties

  /// The original input volume accessor.
  private let inputVolume: VolumeDataAccessor
  /// The size (in voxels) of each brick.
  private let brickSize: Int
  /// The overlap (in voxels) between adjacent bricks.
  private let overlap: Int
  /// The strategy to extend the volume beyond its boundaries.
  private let extensionStrategy: ExtensionStrategy
  /// A list of temporary file paths that need to be cleaned up.
  private var cleanupList: [String]

  // MARK: - Initialization

  /**
   Initializes a new reorganizer.

   - Parameters:
   - inputVolume: The volume accessor providing the monolithic volume.
   - brickSize: The size of each brick in voxels.
   - overlap: The number of voxels by which bricks overlap.
   - extensionStrategy: The strategy to use when voxels are requested outside the original volume.
   */
  public init(inputVolume: VolumeDataAccessor,
              brickSize: Int,
              overlap: Int,
              extensionStrategy: ExtensionStrategy) {
    self.inputVolume = inputVolume
    self.brickSize = brickSize
    self.overlap = overlap
    self.extensionStrategy = extensionStrategy
    self.cleanupList = []
  }

  // MARK: - Private Helper Methods

  /**
   Determines if a brick at the given coordinates is a boundary brick.

   - Parameters:
   - volumeSize: The size of the original volume.
   - x: The x-coordinate of the brick’s starting position.
   - y: The y-coordinate of the brick’s starting position.
   - z: The z-coordinate of the brick’s starting position.
   - Returns: `true` if the brick touches a boundary of the volume.
   */
  private func isBoundaryBrick(volumeSize: Vec3<Int>, x: Int, y: Int, z: Int) -> Bool {
    return x == 0 || (x - overlap + brickSize) >= volumeSize.x ||
    y == 0 || (y - overlap + brickSize) >= volumeSize.y ||
    z == 0 || (z - overlap + brickSize) >= volumeSize.z
  }

  /**
   Truncates the file at the given path to the specified length.

   - Parameters:
   - path: The file path.
   - length: The new length in bytes.
   - Throws: An error if file truncation fails.
   */
  private func truncateFile(atPath path: String, toLength length: UInt64) throws {
    let fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    defer { try? fileHandle.close() }
    try fileHandle.truncate(atOffset: length)
  }

  /**
   Fills a brick's data by reading from the source volume and handling boundaries.

   - Parameters:
   - source: The volume accessor from which to read.
   - x: The starting x-coordinate for this brick.
   - y: The starting y-coordinate for this brick.
   - z: The starting z-coordinate for this brick.
   - isBoundaryBrick: Whether this brick is at a boundary.
   - brickData: An inout array where the brick’s data will be written.
   - Throws: An error if voxel data cannot be read.
   */
  private func fillBrick(source: VolumeDataAccessor,
                         x: Int, y: Int, z: Int,
                         isBoundaryBrick: Bool,
                         brickData: inout [UInt8]) throws  {
    var pos = 0

    if isBoundaryBrick {
      for zOffset in 0..<brickSize {
        for yOffset in 0..<brickSize {
          for xOffset in 0..<brickSize {
            let voxelValue = try getExtendedValue(source: source,
                                                  x: x + xOffset - overlap,
                                                  y: y + yOffset - overlap,
                                                  z: z + zOffset - overlap)
            memcpy(&brickData[pos], voxelValue, voxelValue.count)
            pos += voxelValue.count
          }
        }
      }
    } else {
      for zOffset in 0..<brickSize {
        for yOffset in 0..<brickSize {
          let voxelValue: [UInt8] = try source.getData(x: x - overlap,
                                                       y: y + yOffset - overlap,
                                                       z: z + zOffset - overlap,
                                                       count: brickSize)
          memcpy(&brickData[pos], voxelValue, voxelValue.count)
          pos += voxelValue.count
        }
      }
    }
  }

  /**
   Retrieves the voxel data at the given coordinates, handling cases where the coordinates are out of bounds.

   - Parameters:
   - source: The volume accessor.
   - x: The x-coordinate.
   - y: The y-coordinate.
   - z: The z-coordinate.
   - Returns: An array of bytes representing the voxel value.
   - Throws: An error if data cannot be read.
   */
  private func getExtendedValue(source: VolumeDataAccessor,
                                x: Int, y: Int, z: Int) throws -> [UInt8] {
    if x >= 0 && x < source.size.x &&
        y >= 0 && y < source.size.y &&
        z >= 0 && z < source.size.z {
      return try source.getData(x: x, y: y, z: z)
    } else {
      switch extensionStrategy {
        case .fillZeroes:
          return [UInt8](repeating: 0, count: source.componentCount * source.bytesPerComponent)
        case .clamp:
          let clampedX = max(0, min(x, source.size.x - 1))
          let clampedY = max(0, min(y, source.size.y - 1))
          let clampedZ = max(0, min(z, source.size.z - 1))
          return try source.getData(x: clampedX, y: clampedY, z: clampedZ)
        case .repeatValue:
          let repeatedX = (x + source.size.x) % source.size.x
          let repeatedY = (y + source.size.y) % source.size.y
          let repeatedZ = (z + source.size.z) % source.size.z
          return try source.getData(x: repeatedX, y: repeatedY, z: repeatedZ)
      }
    }
  }

  /**
   Compresses the given data using the specified compression algorithm.

   - Parameters:
   - data: The input data as an array of `UInt8`.
   - algorithm: The compression algorithm to use.
   - Returns: A compressed array of `UInt8` if compression is successful; otherwise, `nil`.
   */
  private func compress(data: [UInt8], algorithm: compression_algorithm) -> [UInt8]? {
    let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
    defer { destinationBuffer.deallocate() }

    let compressedSize = data.withUnsafeBytes { sourceBuffer in
      compression_encode_buffer(destinationBuffer,
                                data.count,
                                sourceBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                data.count,
                                nil,
                                algorithm)
    }

    guard compressedSize != 0, compressedSize < data.count else {
      return nil
    }

    return Array(UnsafeBufferPointer(start: destinationBuffer, count: compressedSize))
  }

  // MARK: - Public Methods

  /**
   Reorganizes the input volume into a hierarchical bricked format and writes the output data and metadata to files.

   - Parameters:
   - filename: The base filename for output (the data file will have a `.data` extension and the metadata a `.meta` extension).
   - datasetDescription: A textual description of the dataset.
   - useCompressor: Whether to use compression (currently LZ4) for each brick.
   - logger: An optional logger to track progress.
   - Throws: An error if any file or I/O operation fails.
   */
  public func reorganize(to filename: String,
                         datasetDescription: String,
                         useCompressor: Bool = false,
                         logger: LoggerBase? = nil) throws {

    var maxValue: Int = 0
    var minValue: Int = (1 << (inputVolume.bytesPerComponent * 8)) - 1

    // Create metadata for the volume.
    let metaData = BORGVRMetaData(width: inputVolume.size.x,
                                  height: inputVolume.size.y,
                                  depth: inputVolume.size.z,
                                  componentCount: inputVolume.componentCount,
                                  bytePerComponent: inputVolume.bytesPerComponent,
                                  aspectX: inputVolume.aspect.x,
                                  aspectY: inputVolume.aspect.y,
                                  aspectZ: inputVolume.aspect.z,
                                  brickSize: brickSize,
                                  overlap: overlap,
                                  minValue: minValue,
                                  maxValue: maxValue,
                                  compression: useCompressor,
                                  datasetDescription: datasetDescription)



    let levelCount = BORGVRMetaData.calculateLevelCount(size: inputVolume.size,
                                                        brickSize: brickSize,
                                                        overlap: overlap)
    let maxOutputFileSize = BORGVRMetaData.calculateMaxOutputFileSize(size: inputVolume.size,
                                                                      brickSize: brickSize,
                                                                      overlap: overlap,
                                                                      elemSize: inputVolume.componentCount * inputVolume.bytesPerComponent)

    let memoryMappedFile = try MemoryMappedFile(filename: filename, size: Int64(maxOutputFileSize))
    defer { try? memoryMappedFile.close() }

    var source: VolumeDataAccessor = inputVolume
    var filePos = 8 // leaving space for the metadata offset

    // Process each level in the bricked hierarchy.
    for level in 0..<levelCount {
      filePos = try reorganizeLevel(from: source,
                                    to: memoryMappedFile,
                                    at: filePos,
                                    metaData: metaData,
                                    useCompressor: useCompressor,
                                    logger: logger)
      if level < levelCount - 1 {
        // Create a temporary file for the subsampled volume.
        let tempDirectory = FileManager.default.temporaryDirectory
        let uniqueFileName = UUID().uuidString
        let tempURL = tempDirectory.appendingPathComponent(uniqueFileName)

        if level == 0 && inputVolume.componentCount == 1 {
          source = try subsample(tempName: tempURL.path, volume: source,
                                 minValue: &minValue, maxValue: &maxValue,
                                 logger: logger)
          logger?.dev("Min value: \(minValue), Max value: \(maxValue)")
        } else {
          source = try subsample(tempName: tempURL.path, volume: source,
                                 logger: logger)
        }
      }
    }

    // Store offset to metadata at the beginning of the file.
    let pointer = memoryMappedFile.mappedMemory.assumingMemoryBound(to: UInt64.self)
    pointer[0] = UInt64(filePos)

    try memoryMappedFile.close()
    try truncateFile(atPath: filename, toLength: UInt64(filePos))

    // Clean up temporary files.
    for name in cleanupList {
      try FileManager.default.removeItem(atPath: name)
    }


    metaData.updateMinMax(minValue: minValue, maxValue: maxValue)
    logger?.dev("Writing Metadata")
    logger?.dev("\(metaData)")
    try metaData.save(filename: filename)
    logger?.info("Reorganization complete")

    logFileSize(for: filename, using: logger)
  }

  func logFileSize(for filename: String, using logger: LoggerBase?) {
    guard let logger = logger else { return }

    let url = URL(fileURLWithPath: filename)

    do {
      let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
      if let size = resourceValues.fileSize {
        logger.dev("File size: \(size) byte\(size == 1 ? "" : "s")")
      } else {
        logger.warning("Could not determine file size for file: \(filename)")
      }
    } catch {
      logger.warning("Failed to get file size for file: \(filename): \(error.localizedDescription)")
    }
  }

  /**
   Updates the provided min and max values based on the given integer value.

   - Parameters:
   - value: The new value to consider.
   - minValue: The current minimum value (modified in-place).
   - maxValue: The current maximum value (modified in-place).
   */
  private func updateMinMax<T: FixedWidthInteger & Comparable>(value: T,
                                                               minValue: inout Int,
                                                               maxValue: inout Int) {
    if Int(value) < minValue {
      minValue = Int(value)
    }
    if Int(value) > maxValue {
      maxValue = Int(value)
    }
  }

  // MARK: - Subsampling

  /**
   Protocol toggle for enabling or disabling min/max computation during subsampling.
   */
  private protocol ComputeMinMaxToggle {
    /// Flag indicating whether min/max computation is enabled.
    static var minMaxComputationEnabled: Bool { get }
  }

  /// Enabled state for min/max computation.
  private struct Enabled: ComputeMinMaxToggle {
    static let minMaxComputationEnabled = true
  }

  /// Disabled state for min/max computation.
  private struct Disabled: ComputeMinMaxToggle {
    static let minMaxComputationEnabled = false
  }

  /**
   Subsamples the volume by a factor of 2, computing min/max values.

   - Parameters:
   - tempName: The temporary filename where the downsampled volume will be stored.
   - volume: The source volume accessor.
   - minValue: The current minimum value (modified in-place).
   - maxValue: The current maximum value (modified in-place).
   - logger: An optional logger for progress updates.
   - Returns: A new volume accessor for the downsampled volume.
   - Throws: An error if any I/O or subsampling operation fails.
   */
  func subsample(tempName: String,
                 volume: VolumeDataAccessor,
                 minValue: inout Int,
                 maxValue: inout Int,
                 logger: LoggerBase? = nil) throws -> VolumeDataAccessor {
    return try subsampleGeneric(
      tempName: tempName,
      volume: volume,
      minMaxComputation: Enabled.self,
      minValue: &minValue,
      maxValue: &maxValue,
      logger: logger
    )
  }

  /**
   Subsamples the volume by a factor of 2 without computing min/max values.

   - Parameters:
   - tempName: The temporary filename where the downsampled volume will be stored.
   - volume: The source volume accessor.
   - logger: An optional logger for progress updates.
   - Returns: A new volume accessor for the downsampled volume.
   - Throws: An error if any I/O or subsampling operation fails.
   */
  func subsample(tempName: String,
                 volume: VolumeDataAccessor,
                 logger: LoggerBase? = nil) throws -> VolumeDataAccessor {
    var d1 = 0
    var d2 = 0
    return try subsampleGeneric(
      tempName: tempName,
      volume: volume,
      minMaxComputation: Disabled.self,
      minValue: &d1,
      maxValue: &d2,
      logger: logger
    )
  }

  /**
   Creates a downsampled (by a factor of 2) version of the given volume and returns a new volume accessor.

   - Parameters:
   - tempName: The temporary filename where the downsampled volume will be stored.
   - volume: The source volume accessor.
   - minMaxComputation: A toggle type indicating whether to compute min/max values.
   - minValue: The current minimum value (modified in-place).
   - maxValue: The current maximum value (modified in-place).
   - logger: An optional logger for progress updates.
   - Returns: A new volume accessor for the downsampled volume.
   - Throws: An error if any I/O or subsampling operation fails.
   */
  private func subsampleGeneric<T: ComputeMinMaxToggle>(
    tempName: String,
    volume: VolumeDataAccessor,
    minMaxComputation: T.Type,
    minValue: inout Int,
    maxValue: inout Int,
    logger: LoggerBase? = nil
  ) throws -> VolumeDataAccessor {
    logger?.info("Subsampling")

    let newSize = Vec3<Int>(
      x: (volume.size.x + 1) / 2,
      y: (volume.size.y + 1) / 2,
      z: (volume.size.z + 1) / 2
    )

    // Create an empty file of the required size.
    let fileSize = newSize.x * newSize.y * newSize.z * volume.bytesPerComponent * volume.componentCount
    _ = try MemoryMappedFile(filename: tempName, size: Int64(fileSize))
    cleanupList.append(tempName)

    let target = try RawFileAccessor(
      filename: tempName,
      size: newSize,
      bytesPerComponent: volume.bytesPerComponent,
      componentCount: volume.componentCount,
      aspect: volume.aspect,
      offset: 0,
      readOnly: false
    )

    switch volume.bytesPerComponent {
      case 1:
        var data = [UInt8](repeating: 0, count: volume.componentCount)
        var sum = [UInt16](repeating: 0, count: volume.componentCount)
        for z in 0..<newSize.z {
          logger?.progress("Subsampling", Double(z) / Double(newSize.z))
          for y in 0..<newSize.y {
            for x in 0..<newSize.x {
              _ = sum.withUnsafeMutableBufferPointer { buffer in
                memset(buffer.baseAddress, 0, buffer.count * MemoryLayout<UInt16>.stride)
              }
              var count: UInt16 = 0
              for dz in 0...1 {
                for dy in 0...1 {
                  for dx in 0...1 {
                    let origX = x * 2 + dx
                    let origY = y * 2 + dy
                    let origZ = z * 2 + dz
                    if origX < volume.size.x && origY < volume.size.y && origZ < volume.size.z {
                      let voxelData: [UInt8] = try volume.getData(x: origX, y: origY, z: origZ)

                      if T.minMaxComputationEnabled {
                        updateMinMax(value: voxelData[0], minValue: &minValue, maxValue: &maxValue)
                      }

                      for i in 0..<volume.componentCount {
                        sum[i] += UInt16(voxelData[i])
                      }
                      count += 1
                    }
                  }
                }
              }
              for i in 0..<volume.componentCount {
                data[i] = UInt8(sum[i] / count)
              }
              try target.setData(x: x, y: y, z: z, data: data)
            }
          }
        }

      case 2:
        var data = [UInt16](repeating: 0, count: volume.componentCount)
        var sum = [UInt32](repeating: 0, count: volume.componentCount)
        for z in 0..<newSize.z {
          logger?.progress("Subsampling", Double(z) / Double(newSize.z))
          for y in 0..<newSize.y {
            for x in 0..<newSize.x {
              _ = sum.withUnsafeMutableBufferPointer { buffer in
                memset(buffer.baseAddress, 0, buffer.count * MemoryLayout<UInt32>.stride)
              }
              var count: UInt32 = 0
              for dz in 0...1 {
                for dy in 0...1 {
                  for dx in 0...1 {
                    let origX = x * 2 + dx
                    let origY = y * 2 + dy
                    let origZ = z * 2 + dz
                    if origX < volume.size.x && origY < volume.size.y && origZ < volume.size.z {
                      let voxelData: [UInt16] = try volume.getData(x: origX, y: origY, z: origZ)

                      if T.minMaxComputationEnabled {
                        updateMinMax(value: voxelData[0], minValue: &minValue, maxValue: &maxValue)
                      }

                      for i in 0..<volume.componentCount {
                        sum[i] += UInt32(voxelData[i])
                      }
                      count += 1
                    }
                  }
                }
              }
              for i in 0..<volume.componentCount {
                data[i] = UInt16(sum[i] / count)
              }
              try target.setData(x: x, y: y, z: z, data: data)
            }
          }
        }

      case 4:
        var data = [UInt32](repeating: 0, count: volume.componentCount)
        var sum = [UInt64](repeating: 0, count: volume.componentCount)
        for z in 0..<newSize.z {
          logger?.progress("Subsampling", Double(z) / Double(newSize.z))
          for y in 0..<newSize.y {
            for x in 0..<newSize.x {
              _ = sum.withUnsafeMutableBufferPointer { buffer in
                memset(buffer.baseAddress, 0, buffer.count * MemoryLayout<UInt64>.stride)
              }
              var count: UInt64 = 0
              for dz in 0...1 {
                for dy in 0...1 {
                  for dx in 0...1 {
                    let origX = x * 2 + dx
                    let origY = y * 2 + dy
                    let origZ = z * 2 + dz
                    if origX < volume.size.x && origY < volume.size.y && origZ < volume.size.z {
                      let voxelData: [UInt32] = try volume.getData(x: origX, y: origY, z: origZ)

                      if T.minMaxComputationEnabled {
                        updateMinMax(value: voxelData[0], minValue: &minValue, maxValue: &maxValue)
                      }

                      for i in 0..<volume.componentCount {
                        sum[i] += UInt64(voxelData[i])
                      }
                      count += 1
                    }
                  }
                }
              }
              for i in 0..<volume.componentCount {
                data[i] = UInt32(sum[i] / count)
              }
              try target.setData(x: x, y: y, z: z, data: data)
            }
          }
        }

      default:
        fatalError("\(#function): Unsupported data byte \(volume.bytesPerComponent)")
    }

    logger?.progress("Subsampling", 1.0)
    return target
  }

  /**
   A generic helper that computes the minimum and maximum values and builds a histogram for an array of fixed‑width integers.

   - Parameter values: An array of values of type T.
   - Returns: A tuple containing:
   - minValue: The minimum value found.
   - maxValue: The maximum value found.
   - histogram: An array of counts for each value in the range [minValue, maxValue].
   */
  func computeHistogramForValues<T: FixedWidthInteger & Comparable>(values: [T]) -> (minValue: Int, maxValue: Int, histogram: [Int]) {
    if let minVal = values.min(), let maxVal = values.max() {
      let histLength = Int(maxVal - minVal) + 1
      var histogram = [Int](repeating: 0, count: histLength)
      for value in values {
        let index = Int(value) - Int(minVal)
        histogram[index] += 1
      }
      return (minValue: Int(minVal), maxValue: Int(maxVal), histogram: histogram)
    } else {
      return (minValue: 0, maxValue: 0, histogram: [])
    }
  }

  /**
   Computes statistics about the raw byte array data, interpreting it according to `inputVolume.componentCount` and `inputVolume.bytesPerComponent`.

   - Parameter data: A flat array of `UInt8` containing the raw data.
   - Returns: A tuple containing:
   - minValue: The smallest value that appears.
   - maxValue: The largest value that appears.
   - histogram: An array of counts for each value in the range [minValue, maxValue].
   */
  func computeHistogram(data: [UInt8]) -> (minValue: Int, maxValue: Int, histogram: [Int]) {
    if inputVolume.componentCount != 1 {
      return (minValue: 0, maxValue: 0, histogram: [])
    }

    switch inputVolume.bytesPerComponent {
      case 1:
        return computeHistogramForValues(values: data)
      case 2:
        guard data.count % 2 == 0 else {
          return (minValue: 0, maxValue: 0, histogram: [])
        }
        let values: [UInt16] = data.withUnsafeBytes { rawBuffer in
          let buffer = rawBuffer.bindMemory(to: UInt16.self)
          return Array(buffer)
        }
        return computeHistogramForValues(values: values)
      case 4:
        guard data.count % 4 == 0 else {
          return (minValue: 0, maxValue: 0, histogram: [])
        }
        let values: [UInt32] = data.withUnsafeBytes { rawBuffer in
          let buffer = rawBuffer.bindMemory(to: UInt32.self)
          return Array(buffer)
        }
        return computeHistogramForValues(values: values)
      default:
        return (minValue: 0, maxValue: 0, histogram: [])
    }
  }

  /**
   Processes a single level of the volume by partitioning it into bricks.

   - Parameters:
   - source: The volume accessor for the current level.
   - target: The memory-mapped file where the brick data will be written.
   - startPos: The starting byte offset within the target file.
   - metaData: The metadata object that will be updated with brick information.
   - useCompressor: Whether to compress the brick data.
   - logger: An optional logger for progress updates.
   - Returns: The updated file position after writing the bricks.
   - Throws: An error if any I/O operation fails.
   */
  func reorganizeLevel(from source: VolumeDataAccessor,
                       to target: MemoryMappedFile,
                       at startPos: Int,
                       metaData: BORGVRMetaData,
                       useCompressor: Bool = false,
                       logger: LoggerBase? = nil) throws -> Int {
    var filePos = startPos

    let brickCount = BORGVRMetaData.calculateOutputBrickCount(size: source.size,
                                                              brickSize: brickSize,
                                                              overlap: overlap)
    let totalBricks = brickCount.x * brickCount.y * brickCount.z
    logger?.info("Bricking level into \(brickCount.x) x \(brickCount.y) x \(brickCount.z) bricks. Total: \(totalBricks)")

    var brickIndex = 0
    var brickData = [UInt8](repeating: 0,
                            count: brickSize * brickSize * brickSize * source.componentCount * source.bytesPerComponent)
    let bStride = brickSize - 2 * overlap

    var compressedBrickCounter = 0
    var uncompressedBrickCounter = 0

    for z in stride(from: 0, to: source.size.z, by: bStride) {
      for y in stride(from: 0, to: source.size.y, by: bStride) {
        for x in stride(from: 0, to: source.size.x, by: bStride) {
          let isBoundary = isBoundaryBrick(volumeSize: source.size, x: x, y: y, z: z)
          try fillBrick(source: source,
                        x: x, y: y, z: z,
                        isBoundaryBrick: isBoundary,
                        brickData: &brickData)

          let pointer = target.mappedMemory.advanced(by: filePos).assumingMemoryBound(to: UInt8.self) 

          var brickSizeInBytes = 0
          let stats = computeHistogram(data: brickData)

          if useCompressor {
            if let compressedData = compress(data: brickData, algorithm: COMPRESSION_LZ4) {
              brickSizeInBytes = compressedData.count
              memcpy(pointer, compressedData, brickSizeInBytes)
              compressedBrickCounter+=1
            } else {
              brickSizeInBytes = brickData.count
              memcpy(pointer, brickData, brickSizeInBytes)
              uncompressedBrickCounter+=1
            }
          } else {
            brickSizeInBytes = brickData.count
            memcpy(pointer, brickData, brickSizeInBytes)
          }

          metaData.append(offset: filePos,
                          size: brickSizeInBytes,
                          minValue: stats.minValue,
                          maxValue: stats.maxValue)
          filePos += brickSizeInBytes
          brickIndex += 1
        }
        logger?.progress("Bricking", Double(brickIndex) / Double(totalBricks))
      }
    }

    if useCompressor {
      logger?.dev(
        "Compressed \(compressedBrickCounter) \(compressedBrickCounter == 1 ? "brick" : "bricks"), " +
        "uncompressed \(uncompressedBrickCounter) \(uncompressedBrickCounter == 1 ? "brick" : "bricks")"
      )
    }

    return filePos
  }
}

/*
 Copyright (c) 2025 Computer Graphics and Visualization Group, University of Duisburg-Essen

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
