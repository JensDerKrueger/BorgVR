import Foundation
import Compression

// MARK: - Custom Error Type

/**
 An enum representing errors that can occur in BORGVRData operations.
 */
enum BORGVRDataError: Error, LocalizedError {
  /// Indicates that the memory mapping is nil.
  case memoryMappingIsNil
  /// Indicates that compression buffers were not allocated.
  case compressionBuffersUnavailable
  /// Indicates that decompression failed.
  case decompressionFailed
  /// Indicates that the decompressed data size did not match what was expected.
  case decompressedSizeMismatch(expected: Int, got: Int)
  /// Indicates that an error occurred during network communication.
  case networkError(message: String)
  /// Indicates that the requested brick is not loaded yet, try again later.
  case brickNotYetAvailable(index: Int)
  /// Indicates that the requested synthetic desription is unknown
  case unknownDataDescription(description: String)

  /// A localized description of the error.
  var errorDescription: String? {
    switch self {
      case .memoryMappingIsNil:
        return "Memory mapping is nil."
      case .compressionBuffersUnavailable:
        return "Compression buffers not allocated."
      case .decompressionFailed:
        return "Failed to decompress data."
      case .decompressedSizeMismatch(let expected, let got):
        return "Decompressed size mismatch (expected \(expected), got \(got))."
      case .networkError(let message):
        return "Error during network request: (\(message))."
      case .brickNotYetAvailable(let index):
        return "Brick \(index) is not loaded yet, try again later."
      case .unknownDataDescription(let description):
        return "Unknown dataset description: \(description)"
    }
  }
}

// MARK: - BORGVRDataset

/**
 A protocol that defines the interface for a BorgVR dataset.

 Implementers of this protocol must provide methods to:
 - Retrieve dataset metadata.
 - Load a specific brick into an output buffer.
 - Allocate a new memory buffer suitable for storing a brick.
 */
protocol BORGVRDatasetProtocol {

  /// let the dataset know that new requests are coming
  /// an async dataset may use this to invalidate outstanding
  /// requests
  func newRequest()

  /// Returns the metadata describing the dataset.
  func getMetadata() -> BORGVRMetaData

  /**
   Loads a brick from the dataset at the given index and copies its data into the provided output buffer.

   - Parameter index: The index of the brick to load.
   - Parameter outputBuffer: A pointer to a memory area with sufficient capacity for the brick data.
   - Throws: An error of type `BORGVRDataError` if the brick cannot be loaded.
   */
  func getBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws

  /**
   Loads the first brick from the dataset into the provided output buffer.
   In contrast to getBrick, this call is always synchronous.

   - Parameter outputBuffer: A pointer to a memory area with sufficient capacity for the brick data.
   - Throws: An error if the brick cannot be loaded.
   */
  func getFirstBrick(outputBuffer: UnsafeMutablePointer<UInt8>) throws

  /**
   Allocates and returns a new memory buffer suitable for storing a brick.

   - Returns: A pointer to a newly allocated memory buffer.
   - Note: The caller is responsible for deallocating the returned buffer.
   */
  func allocateBrickBuffer() -> UnsafeMutablePointer<UInt8>
}

/*
 Copyright (c) 2025 Computer Graphics and Visualization Group, University of
 Duisburg-Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of
 this software and associated documentation files (the "Software"), to deal in
 the Software without restriction, including without limitation the rights to
 use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
 the Software, and to permit persons to whom the Software is furnished to do so,
 subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
 FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
 COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
 IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
 WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
