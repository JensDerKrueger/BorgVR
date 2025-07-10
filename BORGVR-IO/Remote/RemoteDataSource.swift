import Metal
import Foundation
import Compression
import Network

/**
 A remote data source for BorgVR volume data.

 RemoteDataSource implements the DataSource protocol to retrieve brick data from a remote server over a TCP
 connection. It sends commands and receives binary responses, handling decompression when necessary.
 */
final class RemoteDataSource: DataSource {
  /// The underlying NWConnection used for communication with the remote server.
  private let connection: NWConnection
  /// The dataset ID for the remote dataset.
  private let datasetID: Int
  /// Indicates whether the remote dataset is open.
  private var isOpen: Bool
  /// The metadata for the remote dataset.
  private var metadata: BORGVRMetaData
  /// An optional logger for debug and error messages.
  private let logger: LoggerBase?


  /// A scratch buffer used during decompression (allocated only if compression is enabled).
  private var compressionScratchBuffer: UnsafeMutableRawPointer?
  /// A temporary buffer used to hold compressed brick data.
  private var compressedDataBuffer: UnsafeMutablePointer<UInt8>?
  /// The expected full size in bytes of a brick.
  private var fullBrickSize: Int

  /**
   Initializes a new RemoteDataSource with the given connection and dataset ID.

   - Parameters:
   - connection: The NWConnection to the remote server.
   - datasetID: The identifier for the dataset to open.
   - Throws: An error if sending the "OPEN" command fails or if metadata cannot be parsed.
   */
  init(connection: NWConnection, datasetID: Int, logger: LoggerBase?) throws {
    self.connection = connection
    self.datasetID = datasetID
    self.isOpen = false
    self.logger = logger

    // Send the OPEN command to the server with the dataset ID.
    try RemoteDataSource.sendCommand("OPEN \(datasetID)", connection: connection)
    // Receive the binary response containing the metadata.
    let responseData = try RemoteDataSource.receiveBinaryData(connection: connection)

    // Parse the metadata from the received data.
    self.metadata = try BORGVRMetaData(fromData: responseData)
    self.isOpen = true

    // Compute the full brick size based on metadata.
    self.fullBrickSize = metadata.brickSize * metadata.brickSize * metadata.brickSize *
    metadata.componentCount * metadata.bytesPerComponent

    // Allocate compression buffers if compression is enabled.
    if metadata.compression {
      let scratchBufferSize = compression_decode_scratch_buffer_size(COMPRESSION_LZ4)
      compressionScratchBuffer = UnsafeMutableRawPointer.allocate(
        byteCount: scratchBufferSize,
        alignment: MemoryLayout<UInt8>.alignment
      )
      compressedDataBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: fullBrickSize)
    } else {
      compressionScratchBuffer = nil
      compressedDataBuffer = nil
    }
  }

  deinit {
    // Clean up allocated buffers and cancel the connection.
    compressionScratchBuffer?.deallocate()
    compressedDataBuffer?.deallocate()
    connection.cancel()
  }

  /**
   Loads a raw brick from the remote dataset and copies its data into the provided output buffer.

   - Parameters:
   - index: The index of the brick to load.
   - outputBuffer: A pointer to the memory area to copy the brick data.
   - Returns: The BrickMetadata for the loaded brick.
   - Throws: An error if the brick cannot be loaded.
   */
  func getRawBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws -> BrickMetadata {
    let brickMeta = metadata.brickMetadata[index]
    try sendCommand("GETBRICK \(index)")
    let responseData = try receiveBinaryData()
    responseData.copyBytes(to: outputBuffer, count: responseData.count)
    return brickMeta
  }

  /**
   Loads the first brick from the remote dataset into the provided output buffer.
   In contrast to getBrick, this call is always synchronous.

   - Parameter outputBuffer: A pointer to the memory area to copy the brick data.
   - Throws: An error if the brick cannot be loaded.
   */
  func getFirstBrick(outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    let minResBrick = metadata.brickMetadata.count - 1
    try getBrick(index: minResBrick, outputBuffer: outputBuffer)
  }

  /**
   Loads a brick from the remote dataset at the specified index and writes its data into the provided buffer.

   If compression is enabled and the received brick size is smaller than the full brick size,
   the brick data is decompressed into the output buffer.

   - Parameters:
   - index: The index of the brick to load.
   - outputBuffer: A pointer to the memory area to copy the brick data.
   - Throws: An error if the brick cannot be loaded or decompressed.
   */
  func getBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    let brickMeta = metadata.brickMetadata[index]

    try sendCommand("GETBRICK \(index)")
    let responseData = try receiveBinaryData()

    if metadata.compression && brickMeta.size < fullBrickSize {
      guard let compBuffer = compressedDataBuffer, let scratchBuffer = compressionScratchBuffer else {
        throw BORGVRDataError.compressionBuffersUnavailable
      }
      responseData.copyBytes(to: compBuffer, count: responseData.count)

      let decompressedSize = compression_decode_buffer(
        outputBuffer,
        fullBrickSize,
        compBuffer,
        brickMeta.size,
        scratchBuffer,
        COMPRESSION_LZ4
      )
      if decompressedSize == 0 {
        throw BORGVRDataError.decompressionFailed
      } else if decompressedSize != fullBrickSize {
        throw BORGVRDataError.decompressedSizeMismatch(expected: fullBrickSize, got: decompressedSize)
      }
    } else {
      responseData.copyBytes(to: outputBuffer, count: responseData.count)
    }
  }

  /**
   Sends a command string to the remote server over the provided connection.

   - Parameters:
   - command: The command string to send.
   - connection: The NWConnection to use.
   - Throws: A BORGVRDataError.networkError if sending fails.
   */
  static private func sendCommand(_ command: String, connection: NWConnection) throws {
    let semaphore = DispatchSemaphore(value: 0)
    var sendError: Error?

    let terminatedCommand = command + "\n"
    guard let commandData = terminatedCommand.data(using: .utf8) else {
      throw BORGVRRemoteDataManagerError.sendFailed(
        NSError(domain: "Encoding", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode command"])
      )
    }

    connection.send(content: commandData, completion: .contentProcessed({ error in
      sendError = error
      semaphore.signal()
    }))

    let result = semaphore.wait(timeout: .now() + 5)
    if result == .timedOut {
      throw BORGVRRemoteDataManagerError.timeout(seconds: 5)
    }
    if let error = sendError {
      throw BORGVRRemoteDataManagerError.sendFailed(error)
    }
  }

  /**
   Sends a command string using the current connection.

   - Parameter command: The command string to send.
   - Throws: An error if sending fails.
   */
  private func sendCommand(_ command: String) throws {
    try RemoteDataSource.sendCommand(command, connection: connection)
  }

  /**
   Receives binary data from the remote server using the current connection.

   - Returns: The received Data.
   - Throws: A network error if data reception fails.
   */
  private func receiveBinaryData() throws -> Data {
    return try RemoteDataSource.receiveBinaryData(connection: connection)
  }

  /**
   Receives binary data from the specified connection.

   The function first reads a 4-byte size prefix, then receives a payload of that size.

   - Parameter connection: The NWConnection to receive data from.
   - Returns: The received Data payload.
   - Throws: A network error if reception times out or fails.
   */
  static private func receiveBinaryData(connection: NWConnection) throws -> Data {
    var receivedData: Data?
    var sendError: BORGVRDataError?

    // Receive the size prefix (4 bytes for UInt32).
    let sizeSemaphore = DispatchSemaphore(value: 0)
    var dataSize: UInt32 = 0
    connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { sizeData, _, _, error in
      defer { sizeSemaphore.signal() }
      guard let sizeData = sizeData, sizeData.count == 4 else {
        sendError = .networkError(message: "Missing size prefix")
        return
      }
      dataSize = sizeData.withUnsafeBytes { $0.load(as: UInt32.self) }
    }

    if sizeSemaphore.wait(timeout: .now() + 5) == .timedOut {
      throw BORGVRDataError.networkError(message: "Timeout while waiting for data size")
    }

    // Receive the payload.
    let dataSemaphore = DispatchSemaphore(value: 0)
    connection.receive(minimumIncompleteLength: Int(dataSize), maximumLength: Int(dataSize)) { data, _, _, error in
      defer { dataSemaphore.signal() }
      if let data = data {
        receivedData = data
      } else if let error = error {
        sendError = .networkError(message: "Failed to receive data: \(error)")
      }
    }

    if let error = sendError {
      throw error
    }

    if dataSemaphore.wait(timeout: .now() + 5) == .timedOut {
      throw BORGVRDataError.networkError(message: "Timeout while waiting for data")
    }

    guard let result = receivedData else {
      throw BORGVRDataError.networkError(message: "Data was nil after receive")
    }
    return result
  }

  /**
   Retrieves the metadata for the remote dataset.

   - Returns: A BORGVRMetaData instance.
   */
  func getMetadata() -> BORGVRMetaData {
    return metadata
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
