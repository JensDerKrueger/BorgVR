import Metal

/**
 An enum representing errors that can occur in 1D transfer function operations.

 Currently, it supports an error for mismatched data counts.
 */
enum TransferFunction1DError: Error {
  case mismatchedDataCount(expected: Int, found: Int)
}

/**
 A 1D transfer function used for volume rendering.

 TransferFunction1D stores an array of color values (as SIMD4<UInt8>) that define the transfer
 function. It supports resampling, smoothing, and updating texture data for rendering.
 */
@Observable
class TransferFunction1D: Equatable {
  /// The transfer function data represented as an array of RGBA values.
  private(set) var data: [SIMD4<UInt8>]

  /// The minimum index with a non-zero alpha value.
  private(set) var minIndex: Int = -1
  /// The maximum index with a non-zero alpha value.
  private(set) var maxIndex: Int = -1

  /// A bias factor used for mapping data indices.
  private var bias: Float = 1.0
  /// A factor used for adjusting texture lookup.
  private(set) var textureBias: Float = 1.0

  /// The Metal texture used for rendering the transfer function.
  private var texture: MTLTexture?
  /// The Metal device used to create the texture.
  private var device: MTLDevice?

  /**
   Initializes a new TransferFunction1D with the specified bin count

   The number of entries in the transfer function is count (default is 256).

   - Parameter count: The number of elemtns per entry .
   */
  init(count: Int = 256) {
    self.data = Array(repeating: .init(0, 0, 0, 0), count: count)
    reset()
  }

  /**
   Creates a new TransferFunction1D by copying data from another instance.

   - Parameter other: The TransferFunction1D instance to copy from.
   */
  init(copyFrom other: TransferFunction1D) {
    self.data = other.data
    self.minIndex = other.minIndex
    self.maxIndex = other.maxIndex
    self.texture = nil
    self.device = nil
    self.bias = other.bias
    self.textureBias = other.textureBias
  }

  /**
   Creates a new TransferFunction1D by loading the data from a data object

   - Parameter from: The data object to extract the data from
   - Throws: `mismatchedDataCount` if data extraction fails
   */
  init(from data: Data) throws {
    self.data = try Self.parseTransferFunctionData(data)
    updateDataDependencies()
  }

  /**
   Creates a new TransferFunction1D by loading the data from a file

   - Parameter from: The url of the file to loaded
   - Throws: `mismatchedDataCount` if data extraction fails
   */
  convenience init(from url: URL) throws {
    try self.init(from: try Data(contentsOf: url))
  }

  /**
   Loads data from a file

   - Parameter from: The url of the file to loaded
   - Throws: `mismatchedDataCount` if data extraction fails
   */
  func load(from url: URL) throws {
    try load(from: try Data(contentsOf: url))
  }

  /**
   Loads data from a Data Object

   - Parameter from: The Data Object to be processed
   - Throws: `mismatchedDataCount` if data extraction fails
   */
  func load(from data: Data) throws {
    self.data = try Self.parseTransferFunctionData(data)
    updateDataDependencies()
  }

  /// extract the transfer function table from a data object
  private static func parseTransferFunctionData(_ data: Data) throws -> [SIMD4<UInt8>] {
    var cursor = 0

    // Read the count
    guard data.count >= MemoryLayout<UInt32>.size else {
      throw TransferFunction1DError.mismatchedDataCount(expected: 0, found: -1)
    }

    let count = data.withUnsafeBytes { $0.load(fromByteOffset: cursor, as: UInt32.self) }
    cursor += MemoryLayout<UInt32>.size

    // Compute expected size
    let expectedSize = Int(count) * MemoryLayout<SIMD4<UInt8>>.size
    guard data.count >= cursor + expectedSize else {
      throw TransferFunction1DError.mismatchedDataCount(expected: Int(count), found: (data.count - cursor) / 4)
    }

    // Read RGBA values
    var result = Array(repeating: SIMD4<UInt8>(0, 0, 0, 0), count: Int(count))
    _ = result.withUnsafeMutableBytes { dst in
      data.copyBytes(to: dst, from: cursor..<(cursor + dst.count))
    }

    return result
  }

  /**
   Updates the bias and textureBias based on new range values.

   - Parameters:
   - minValue: The minimum value in the new range.
   - maxValue: The maximum value in the new range.
   - rangeMax: The maximum value of the overall range.
   */
  func updateRanges(minValue: Int, maxValue: Int, rangeMax: Int) {
    bias = Float(maxValue) / Float(data.count - 1)
    textureBias = Float(rangeMax) / Float(maxValue)
  }

  /// Resets the transfer function by applying a default smooth step function.
  func reset() {
    smoothStep(start: 0.1, shift: 0.3, channels: [0, 1, 2, 3])
  }

  /// Sets the transfer fucntion to opaque with a color ramp that spawns the entire range
  /// this is usefull when slicing througth the dataset
  func slicingPreset() {
    smoothStep(start: 0, shift: 1, channels: [0, 1, 2])
    smoothStep(start: -1, shift: 0.3, channels: [3])
  }

  /**
   Resamples the transfer function data to a new bit depth.

   - Parameter newBytes: The new number of bytes per entry (supported values: 1 or 2).
   */
  func resample(newBytes: Int) {
    guard newBytes >= 1 && newBytes <= 2 else {
      fatalError("Unsupported newBytes value: \(newBytes)")
    }

    // Calculate the new size: 1 << (newBytes * 8) equals 2^(newBytes*8)
    let newSize = 1 << (newBytes * 8)

    // Exit early if the new size is equal to the current size.
    if newSize == data.count {
      return
    }

    var newData: [SIMD4<UInt8>] = Array(repeating: .init(0, 0, 0, 0), count: newSize)
    let oldSize = data.count

    // If there's only one element, replicate it.
    if oldSize == 1 {
      newData = Array(repeating: data[0], count: newSize)
    } else {
      for i in 0..<newSize {
        // Map the new index to a floating point position in the old array.
        let t = Float(i) * Float(oldSize - 1) / Float(newSize - 1)
        let index0 = Int(t)
        let index1 = min(index0 + 1, oldSize - 1)
        let fraction = t - Float(index0)

        let v0 = data[index0]
        let v1 = data[index1]

        // Linear interpolation for each channel.
        let r = UInt8(round((1 - fraction) * Float(v0.x) + fraction * Float(v1.x)))
        let g = UInt8(round((1 - fraction) * Float(v0.y) + fraction * Float(v1.y)))
        let b = UInt8(round((1 - fraction) * Float(v0.z) + fraction * Float(v1.z)))
        let a = UInt8(round((1 - fraction) * Float(v0.w) + fraction * Float(v1.w)))

        newData[i] = SIMD4<UInt8>(r, g, b, a)
      }
    }

    data = newData
    updateDataDependencies()
  }

  /**
   Applies a smooth step function to the transfer function data.

   This function modifies the specified channels of each entry using a smooth step interpolation.

   - Parameters:
   - start: The start value for the interpolation.
   - shift: The shift value determining the interpolation range.
   - channels: An array of channel indices to update.
   - reverse: If true, the smooth step function is reversed. Defaults to false.
   */
  func smoothStep(start: Float, shift: Float, channels: [Int], reverse: Bool = false) {
    let invFact1: Float = reverse ? -1.0 : 1.0
    let invFact2: Float = reverse ? 1.0 : 0.0
    for i in 0..<data.count {
      let f = Float(i) / Float(data.count - 1)
      let v = (shift == 0) ? 1.0 : clamp((f - start) / shift, 0.0, 1.0)
      for channel in channels {
        data[i][channel] = UInt8(clamp(invFact1 * (Float(v * v * (3 - 2 * v)) - invFact2)) * 255)
      }
    }
    updateDataDependencies()
  }

  /**
   Clamps a floating point value between a minimum and maximum value.

   - Parameters:
   - x: The value to clamp.
   - minVal: The minimum allowed value (default is 0).
   - maxVal: The maximum allowed value (default is 1).
   - Returns: The clamped value.
   */
  private func clamp(_ x: Float, _ minVal: Float = 0, _ maxVal: Float = 1) -> Float {
    return min(max(x, minVal), maxVal)
  }

  public static func == (lhs: TransferFunction1D, rhs: TransferFunction1D) -> Bool {
    return lhs.data == rhs.data
  }

  /**
   Updates the transfer function data with new data and updates associated texture data.

   - Parameter newData: An array of SIMD4<UInt8> to replace the current data.
   - Throws: TransferFunction1DError.mismatchedDataCount if the new data count does not match the current data count.
   */
  func updateData(with newData: [SIMD4<UInt8>]) throws {
    guard newData.count == data.count else {
      throw TransferFunction1DError.mismatchedDataCount(expected: data.count, found: newData.count)
    }
    self.data = newData
    transferDataToTexture()
  }

  /// Updates internal dependencies after data changes, including min/max indices and invalidates texture
  func updateDataDependencies() {
    updateMinMaxIndices()
    self.texture = nil
  }

  /**
   Updates the minimum and maximum indices based on the alpha channel values.

   Only indices with a non-zero alpha value are considered.
   */
  private func updateMinMaxIndices() {
    var newMin: Int? = nil
    var newMax: Int? = nil

    for (index, value) in data.enumerated() {
      if value.w > 0 {
        if newMin == nil {
          newMin = index
        }
        newMax = index
      }
    }

    self.minIndex = newMin ?? -1
    self.maxIndex = newMax ?? -1
  }

  /**
   Creates a Metal texture for the transfer function data.

   This method creates a 1D texture with an RGBA8Unorm pixel format and uploads the current
   transfer function data to the texture.
   */
  private func createTexture() {
    if let device = self.device {
      let descriptor = MTLTextureDescriptor()
      descriptor.textureType = .type1D
      descriptor.pixelFormat = .rgba8Unorm
      descriptor.width = data.count
      descriptor.usage = [.shaderRead]
      descriptor.storageMode = .shared
      self.texture = device.makeTexture(descriptor: descriptor)
      transferDataToTexture()
    }
  }

  /**
   Initializes Metal by setting the device and creating the texture.

   - Parameter device: The MTLDevice to use for texture creation.
   */
  func initMetal(device: MTLDevice) {
    self.device = device
    createTexture()
  }

  /**
   Binds the transfer function texture to the specified fragment texture index.

   - Parameters:
   - encoder: The MTLRenderCommandEncoder to bind the texture to.
   - index: The texture index in the fragment shader.
   */
  func bind(to encoder: MTLRenderCommandEncoder, index: Int) {
    if texture == nil {
      createTexture()
    }

    encoder.setFragmentTexture(texture, index: index)
  }

  /**
   Transfers the current transfer function data to the Metal texture.

   If the texture is not already created, it attempts to create it.
   */
  private func transferDataToTexture() {

    if let texture = self.texture {
      if texture.width != data.count {
        createTexture()
      }

      let wholeTexture = MTLRegionMake1D(0, data.count)
      texture.replace(region: wholeTexture, mipmapLevel: 0, withBytes: data,
                      bytesPerRow: data.count * MemoryLayout<SIMD4<UInt8>>.stride)
    } else {
      createTexture()
    }
  }

  /**
   Checks whether there is a significant change in emptiness between this transfer function and another.

   Emptiness is considered significant if the data count or min/max indices differ.

   - Parameter other: Another TransferFunction1D instance to compare.
   - Returns: True if a significant change is detected; otherwise, false.
   */
  func emptinessSignificantChange(_ other: TransferFunction1D) -> Bool {
    return other.data.count != data.count || other.minIndex != minIndex || other.maxIndex != maxIndex
  }

  /**
   Determines if a given brick (volume subregion) is empty based on its metadata.

   - Parameter brickMetadata: The metadata for the brick.
   - Returns: True if the brick is considered empty; otherwise, false.
   */
  func isBrickEmpty(brickMetadata: BrickMetadata) -> Bool {
    guard minIndex >= 0, maxIndex >= 0 else {
      return true
    }
    let minBrickValue = brickMetadata.minValue
    let maxBrickValue = brickMetadata.maxValue
    return (minBrickValue > Int(ceil(Float(self.maxIndex) * bias))) ||
    (maxBrickValue < Int(Float(self.minIndex) * bias))
  }

  /// Serializes the transfer function into a Data object.
  func serialize() -> Data {
    var buffer = Data()

    // Write data count
    var count = UInt32(data.count)
    buffer.append(Data(bytes: &count, count: MemoryLayout<UInt32>.size))

    // Safely write the RGBA values
    data.withUnsafeBytes { rawBuffer in
      buffer.append(rawBuffer.bindMemory(to: UInt8.self))
    }

    return buffer
  }

  /// Saves the transfer function to a file at the given URL.
  func save(to url: URL) throws {
    let data = serialize()
    try data.write(to: url, options: .atomic)
  }
}

/*
 Copyright (c) 2025 Computer Graphics and Visualization Group, University of Duisburg-
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
