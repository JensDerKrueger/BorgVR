import Foundation

private enum TestFailure: Error, CustomStringConvertible {
  case failed(String)

  var description: String {
    switch self {
      case .failed(let message): return message
    }
  }
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

private func temporaryFile(contents: Data) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("borgvr-raw-accessor-\(UUID().uuidString).raw")
  try contents.write(to: url)
  return url
}

private func withTemporaryFile(
  contents: Data,
  _ body: (URL) throws -> Void
) throws {
  let url = try temporaryFile(contents: contents)
  defer { try? FileManager.default.removeItem(at: url) }
  try body(url)
}

private func bytes<T>(of values: [T]) -> Data {
  values.withUnsafeBytes { Data($0) }
}

private func testFirstAndLastVoxel() throws {
  let values = Array(UInt8(0)..<UInt8(24))
  try withTemporaryFile(contents: Data(values)) { url in
    let accessor = try RawFileAccessor(
      filename: url.path,
      size: Vec3(4, 3, 2),
      bytesPerComponent: 1,
      componentCount: 1,
      voxelSpacing: Vec3(repeating: 1),
      readOnly: true
    )
    let first: [UInt8] = try accessor.getData(x: 0, y: 0, z: 0)
    let last: [UInt8] = try accessor.getData(x: 3, y: 2, z: 1)
    try expect(first == [0], "The first voxel was read incorrectly")
    try expect(last == [23], "The last voxel was read incorrectly")
  }
}

private func testCompleteRangeValidation() throws {
  try withTemporaryFile(contents: Data(repeating: 0, count: 8)) { url in
    let accessor = try RawFileAccessor(
      filename: url.path,
      size: Vec3(2, 2, 2),
      bytesPerComponent: 1,
      componentCount: 1,
      voxelSpacing: Vec3(repeating: 1),
      readOnly: false
    )
    let finalPair: [UInt8] = try accessor.getData(x: 0, y: 1, z: 1, count: 2)
    try expect(finalPair.count == 2, "The final valid range was rejected")
    try expectThrows("A range extending one voxel beyond the volume was accepted") {
      let _: [UInt8] = try accessor.getData(x: 1, y: 1, z: 1, count: 2)
    }
    try expectThrows("A negative voxel count was accepted") {
      let _: [UInt8] = try accessor.getData(x: 0, y: 0, z: 0, count: -1)
    }
    try expectThrows("An out-of-range write was accepted") {
      try accessor.setData(x: 1, y: 1, z: 1, data: [UInt8(1), 2], count: 2)
    }
  }
}

private func testOverflowingDescription() throws {
  try expectThrows("Overflowing volume dimensions were accepted") {
    _ = try RawFileAccessor(
      filename: "/file/that/does/not/need/to/exist",
      size: Vec3(Int.max, 2, 1),
      bytesPerComponent: 4,
      componentCount: 4,
      voxelSpacing: Vec3(repeating: 1),
      readOnly: true
    )
  }
  try expectThrows("A negative header offset was accepted") {
    _ = try RawFileAccessor(
      filename: "/file/that/does/not/need/to/exist",
      size: Vec3(1, 1, 1),
      bytesPerComponent: 1,
      componentCount: 1,
      voxelSpacing: Vec3(repeating: 1),
      offset: -1,
      readOnly: true
    )
  }
}

private func testUnalignedHeaderOffset() throws {
  var data = Data([0x7f])
  data.append(bytes(of: [UInt32(0x11223344), UInt32(0x55667788)]))
  try withTemporaryFile(contents: data) { url in
    let accessor = try RawFileAccessor(
      filename: url.path,
      size: Vec3(2, 1, 1),
      bytesPerComponent: 4,
      componentCount: 1,
      voxelSpacing: Vec3(repeating: 1),
      offset: 1,
      readOnly: false
    )
    let values: [UInt32] = try accessor.getData(x: 0, y: 0, z: 0, count: 2)
    try expect(values == [0x11223344, 0x55667788], "An unaligned payload was read incorrectly")
    try accessor.setData(x: 1, y: 0, z: 0, data: [UInt32(0xaabbccdd)])
    let updated: [UInt32] = try accessor.getData(x: 1, y: 0, z: 0)
    try expect(updated == [0xaabbccdd], "An unaligned payload was written incorrectly")
  }
}

private func testMultichannelComponents() throws {
  try testMultichannel([UInt8(1), 2, 3, 4, 5, 6])
  try testMultichannel([UInt16(10), 20, 30, 40, 50, 60])
  try testMultichannel([UInt32(100), 200, 300, 400, 500, 600])
}

private func testMultichannel<T: FixedWidthInteger & Equatable>(_ values: [T]) throws {
  try withTemporaryFile(contents: bytes(of: values)) { url in
    let accessor = try RawFileAccessor(
      filename: url.path,
      size: Vec3(2, 1, 1),
      bytesPerComponent: MemoryLayout<T>.stride,
      componentCount: 3,
      voxelSpacing: Vec3(repeating: 1),
      readOnly: true
    )
    let result: [T] = try accessor.getData(x: 0, y: 0, z: 0, count: 2)
    try expect(result == values, "A multichannel \(T.self) payload was read incorrectly")
  }
}

@main
private enum RawFileAccessorTestRunner {
  static func main() throws {
    try testFirstAndLastVoxel()
    try testCompleteRangeValidation()
    try testOverflowingDescription()
    try testUnalignedHeaderOffset()
    try testMultichannelComponents()
    print("Raw file accessor tests passed")
  }
}
