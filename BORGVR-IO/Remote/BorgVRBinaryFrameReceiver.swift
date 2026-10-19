import Foundation
import Network

enum BorgVRBinaryFrameError: Error, LocalizedError {
  case invalidSizeLimit
  case timeout(seconds: TimeInterval)
  case receiveFailed(String)
  case emptyResponse
  case payloadTooLarge(received: Int, maximum: Int)

  var errorDescription: String? {
    switch self {
      case .invalidSizeLimit:
        return "The binary response size limit is invalid."
      case .timeout(let seconds):
        return "Receiving binary response data timed out after \(seconds) seconds."
      case .receiveFailed(let reason):
        return "Failed to receive binary response data: \(reason)"
      case .emptyResponse:
        return "The binary response is empty or incomplete."
      case .payloadTooLarge(let received, let maximum):
        return "The binary response declares \(received) bytes, exceeding the \(maximum)-byte limit."
    }
  }
}

enum BorgVRBinaryFrameReceiver {
  typealias ChunkReceiver = (_ minimumLength: Int,
                             _ maximumLength: Int,
                             _ timeout: TimeInterval) throws -> Data

  private static let headerByteCount = MemoryLayout<UInt32>.size
  private static let chunkByteCount = 64 * 1024

  static func receive(
    connection: NWConnection,
    timeout: TimeInterval,
    maximumPayloadSize: Int
  ) throws -> Data {
    try receive(maximumPayloadSize: maximumPayloadSize, timeout: timeout) {
      minimumLength, maximumLength, timeout in
      try receiveChunk(
        connection: connection,
        minimumLength: minimumLength,
        maximumLength: maximumLength,
        timeout: timeout
      )
    }
  }

  static func receive(
    maximumPayloadSize: Int,
    timeout: TimeInterval,
    receiveChunk: ChunkReceiver
  ) throws -> Data {
    guard maximumPayloadSize > 0, timeout > 0 else {
      throw BorgVRBinaryFrameError.invalidSizeLimit
    }

    let header = try receiveExactly(
      headerByteCount,
      timeout: timeout,
      receiveChunk: receiveChunk
    )
    let payloadSize = Int(
      UInt32(header[0])
      | (UInt32(header[1]) << 8)
      | (UInt32(header[2]) << 16)
      | (UInt32(header[3]) << 24)
    )
    guard payloadSize > 0 else {
      throw BorgVRBinaryFrameError.emptyResponse
    }
    guard payloadSize <= maximumPayloadSize else {
      throw BorgVRBinaryFrameError.payloadTooLarge(
        received: payloadSize,
        maximum: maximumPayloadSize
      )
    }

    return try receiveExactly(
      payloadSize,
      timeout: timeout,
      receiveChunk: receiveChunk
    )
  }

  private static func receiveExactly(
    _ byteCount: Int,
    timeout: TimeInterval,
    receiveChunk: ChunkReceiver
  ) throws -> Data {
    var result = Data()
    result.reserveCapacity(byteCount)
    while result.count < byteCount {
      let remaining = byteCount - result.count
      let chunk = try receiveChunk(1, min(remaining, chunkByteCount), timeout)
      guard !chunk.isEmpty, chunk.count <= remaining else {
        throw BorgVRBinaryFrameError.emptyResponse
      }
      result.append(chunk)
    }
    return result
  }

  private static func receiveChunk(
    connection: NWConnection,
    minimumLength: Int,
    maximumLength: Int,
    timeout: TimeInterval
  ) throws -> Data {
    let operation = ReceiveOperation()
    connection.receive(
      minimumIncompleteLength: minimumLength,
      maximumLength: maximumLength
    ) { data, _, _, error in
      operation.finish(data: data, error: error)
    }
    return try operation.wait(timeout: timeout)
  }
}

private final class ReceiveOperation: @unchecked Sendable {
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private var completed = false
  private var data: Data?
  private var error: Error?

  func finish(data: Data?, error: Error?) {
    lock.lock()
    guard !completed else {
      lock.unlock()
      return
    }
    completed = true
    self.data = data
    self.error = error
    lock.unlock()
    semaphore.signal()
  }

  func wait(timeout: TimeInterval) throws -> Data {
    guard semaphore.wait(timeout: .now() + timeout) != .timedOut else {
      lock.lock()
      completed = true
      lock.unlock()
      throw BorgVRBinaryFrameError.timeout(seconds: timeout)
    }

    lock.lock()
    let receivedData = data
    let receiveError = error
    lock.unlock()

    if let receiveError {
      throw BorgVRBinaryFrameError.receiveFailed(receiveError.localizedDescription)
    }
    guard let receivedData, !receivedData.isEmpty else {
      throw BorgVRBinaryFrameError.emptyResponse
    }
    return receivedData
  }
}
