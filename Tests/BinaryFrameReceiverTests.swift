import Foundation

private enum TestFailure: Error, CustomStringConvertible {
  case failed(String)

  var description: String {
    switch self {
      case .failed(let message): return message
    }
  }
}

private enum SourceError: Error {
  case exhausted
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  guard condition() else { throw TestFailure.failed(message) }
}

private func expectThrows(_ message: String, _ body: () throws -> Void) throws {
  do {
    try body()
    throw TestFailure.failed(message)
  } catch is TestFailure {
    throw TestFailure.failed(message)
  } catch {}
}

private func framed(_ payload: Data) -> Data {
  let count = UInt32(payload.count)
  var result = Data([
    UInt8(truncatingIfNeeded: count),
    UInt8(truncatingIfNeeded: count >> 8),
    UInt8(truncatingIfNeeded: count >> 16),
    UInt8(truncatingIfNeeded: count >> 24)
  ])
  result.append(payload)
  return result
}

private final class FragmentedSource {
  private let data: Data
  private let fragmentSizes: [Int]
  private(set) var callCount = 0
  private var offset = 0

  init(data: Data, fragmentSizes: [Int]) {
    self.data = data
    self.fragmentSizes = fragmentSizes
  }

  func receive(minimumLength: Int, maximumLength: Int, timeout: TimeInterval) throws -> Data {
    guard offset < data.count else { throw SourceError.exhausted }
    let requestedFragment = fragmentSizes[min(callCount, fragmentSizes.count - 1)]
    callCount += 1
    let count = min(requestedFragment, maximumLength, data.count - offset)
    guard count >= minimumLength else { throw SourceError.exhausted }
    defer { offset += count }
    return data.subdata(in: offset..<offset + count)
  }
}

private func testFragmentedFrame() throws {
  let payload = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0) })
  let source = FragmentedSource(data: framed(payload), fragmentSizes: [1, 2, 1, 7, 31, 4096])
  let received = try BorgVRBinaryFrameReceiver.receive(
    maximumPayloadSize: payload.count,
    timeout: 1,
    receiveChunk: source.receive
  )
  try expect(received == payload, "A fragmented frame was not reconstructed correctly")
  try expect(source.callCount > 4, "The fragmented test did not exercise multiple receives")
}

private func testOversizedFrameStopsAfterHeader() throws {
  let header = framed(Data(repeating: 1, count: 32)).prefix(4)
  let source = FragmentedSource(data: Data(header), fragmentSizes: [4])
  try expectThrows("An oversized frame was accepted") {
    _ = try BorgVRBinaryFrameReceiver.receive(
      maximumPayloadSize: 16,
      timeout: 1,
      receiveChunk: source.receive
    )
  }
  try expect(source.callCount == 1, "The oversized payload was read after its header was rejected")
}

private func testZeroLengthFrame() throws {
  let source = FragmentedSource(data: Data(repeating: 0, count: 4), fragmentSizes: [4])
  try expectThrows("A zero-length frame was accepted") {
    _ = try BorgVRBinaryFrameReceiver.receive(
      maximumPayloadSize: 1,
      timeout: 1,
      receiveChunk: source.receive
    )
  }
}

private func testTruncatedFrame() throws {
  var data = framed(Data(repeating: 9, count: 8))
  data.removeLast(3)
  let source = FragmentedSource(data: data, fragmentSizes: [4, 5])
  try expectThrows("A truncated frame was accepted") {
    _ = try BorgVRBinaryFrameReceiver.receive(
      maximumPayloadSize: 8,
      timeout: 1,
      receiveChunk: source.receive
    )
  }
}

private func testInvalidLimit() throws {
  let source = FragmentedSource(data: Data(), fragmentSizes: [1])
  try expectThrows("A zero payload limit was accepted") {
    _ = try BorgVRBinaryFrameReceiver.receive(
      maximumPayloadSize: 0,
      timeout: 1,
      receiveChunk: source.receive
    )
  }
  try expect(source.callCount == 0, "The source was read despite an invalid limit")
}

@main
private enum BinaryFrameReceiverTestRunner {
  static func main() throws {
    try testFragmentedFrame()
    try testOversizedFrameStopsAfterHeader()
    try testZeroLengthFrame()
    try testTruncatedFrame()
    try testInvalidLimit()
    print("Binary frame receiver tests passed")
  }
}
