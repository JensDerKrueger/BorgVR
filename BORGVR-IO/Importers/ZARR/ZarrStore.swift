import Foundation
import zlib

enum ZarrImportError: Swift.Error, LocalizedError {
  case invalid(String)
  case unsupported(String)
  var errorDescription: String? {
    switch self {
      case .invalid(let reason): "Invalid Zarr volume: \(reason)."
      case .unsupported(let feature): "Unsupported Zarr feature: \(feature)."
    }
  }
}

/// Read-only key/value access. ZIP entries are read in place, never extracted to paths.
/// ZIP64 and Stored/Deflate are supported; no remote access or archive writing.
final class ZarrStore {
  private struct Member {
    let offset: Int
    let compressed: Int
    let decoded: Int
    let crc: UInt32
    let method: Int
    let flags: Int
  }
  private let root: URL
  private let archive: Data?
  private var members: [String: Member] = [:]
  private var centralDirectoryOffset = 0
  static let maximumChunkBytes = 512 << 20

  init(url: URL) throws {
    root = url.resolvingSymlinksInPath().standardizedFileURL
    if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
      archive = nil
    } else {
      let data = try Data(contentsOf: url, options: .mappedIfSafe)
      archive = data
      try readDirectory(data)
    }
  }

  func read(_ key: String, limit: Int = ZarrStore.maximumChunkBytes) throws -> Data? {
    guard Self.validKey(key) else { throw ZarrImportError.invalid("unsafe store key") }
    if let archive {
      guard let member = members[key] else { return nil }
      guard member.decoded <= limit, member.compressed <= limit + limit / 8 + 1024 else {
        throw ZarrImportError.invalid("ZIP entry exceeds size limit")
      }
      let offset = member.offset
      guard try archive.zarrInteger(offset, 4) == 0x04034b50,
            try archive.zarrInteger(offset + 6, 2) == member.flags,
            try archive.zarrInteger(offset + 8, 2) == member.method else {
        throw ZarrImportError.invalid("ZIP local header")
      }
      let nameLength = try archive.zarrInteger(offset + 26, 2)
      let name = try archive.zarrSlice(offset + 30, nameLength)
      guard String(data: name, encoding: .utf8) == key else { throw ZarrImportError.invalid("ZIP name mismatch") }
      let start = offset + 30 + nameLength + (try archive.zarrInteger(offset + 28, 2))
      guard start <= centralDirectoryOffset, member.compressed <= centralDirectoryOffset - start else {
        throw ZarrImportError.invalid("ZIP payload overlaps central directory")
      }
      let encoded = try archive.zarrSlice(start, member.compressed)
      let decoded: Data
      switch member.method {
        case 0:
          guard member.compressed == member.decoded else { throw ZarrImportError.invalid("Stored ZIP size mismatch") }
          decoded = encoded
        case 8: decoded = try ZarrCompression.inflate(encoded, size: member.decoded, windowBits: -MAX_WBITS)
        default: throw ZarrImportError.unsupported("ZIP compression method \(member.method)")
      }
      let checksum = decoded.withUnsafeBytes { bytes in
        crc32(0, bytes.bindMemory(to: UInt8.self).baseAddress, uInt(bytes.count))
      }
      guard UInt32(checksum) == member.crc else { throw ZarrImportError.invalid("ZIP CRC mismatch") }
      return decoded
    }
    let url = root.appendingPathComponent(key).resolvingSymlinksInPath().standardizedFileURL
    guard url.path.hasPrefix(root.path + "/") else { throw ZarrImportError.invalid("store path escapes directory") }
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard properties.isRegularFile == true, let count = properties.fileSize, count <= limit else {
      throw ZarrImportError.invalid("store entry exceeds size limit or is not a file")
    }
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    guard data.count <= limit else { throw ZarrImportError.invalid("store entry grew beyond size limit") }
    return data
  }

  private static func validKey(_ key: String) -> Bool {
    !key.isEmpty && !key.hasPrefix("/") && !key.contains("\\") && !key.contains("\0") &&
      key.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }

  private func readDirectory(_ data: Data) throws {
    guard data.count >= 22 else { throw ZarrImportError.invalid("missing ZIP central directory") }
    let end = try stride(from: data.count - 22, through: max(0, data.count - 22 - 65535), by: -1).first {
      try data.zarrInteger($0, 4) == 0x06054b50 && $0 + 22 + data.zarrInteger($0 + 20, 2) == data.count
    }
    guard let end, try data.zarrInteger(end + 4, 2) == 0,
          try data.zarrInteger(end + 6, 2) == 0,
          try data.zarrInteger(end + 8, 2) == data.zarrInteger(end + 10, 2) else {
      throw ZarrImportError.invalid("missing ZIP directory or multi-disk archive")
    }
    var count = try data.zarrInteger(end + 10, 2)
    var size = try data.zarrInteger(end + 12, 4)
    var start = try data.zarrInteger(end + 16, 4)
    var directoryEnd = end
    if count == 65535 || size == Int(UInt32.max) || start == Int(UInt32.max) {
      guard end >= 20, try data.zarrInteger(end - 20, 4) == 0x07064b50,
            try data.zarrInteger(end - 16, 4) == 0, try data.zarrInteger(end - 4, 4) == 1 else {
        throw ZarrImportError.invalid("ZIP64 locator")
      }
      let zip64 = try data.zarrInteger(end - 12, 8)
      guard try data.zarrInteger(zip64, 4) == 0x06064b50,
            try data.zarrInteger(zip64 + 16, 4) == 0, try data.zarrInteger(zip64 + 20, 4) == 0,
            try data.zarrInteger(zip64 + 24, 8) == data.zarrInteger(zip64 + 32, 8) else {
        throw ZarrImportError.invalid("ZIP64 directory")
      }
      count = try data.zarrInteger(zip64 + 32, 8)
      size = try data.zarrInteger(zip64 + 40, 8)
      start = try data.zarrInteger(zip64 + 48, 8)
      directoryEnd = zip64
    }
    guard count <= 1000000, start <= directoryEnd, size == directoryEnd - start else {
      throw ZarrImportError.invalid("ZIP directory size")
    }
    centralDirectoryOffset = start
    var cursor = start
    for _ in 0..<count {
      guard try data.zarrInteger(cursor, 4) == 0x02014b50 else { throw ZarrImportError.invalid("ZIP directory entry") }
      let flags = try data.zarrInteger(cursor + 8, 2)
      guard flags & 0x41 == 0, try data.zarrInteger(cursor + 34, 2) == 0 else {
        throw ZarrImportError.unsupported("encrypted or multi-disk ZIP")
      }
      let method = try data.zarrInteger(cursor + 10, 2)
      let crc = UInt32(try data.zarrInteger(cursor + 16, 4))
      var compressed = try data.zarrInteger(cursor + 20, 4)
      var decoded = try data.zarrInteger(cursor + 24, 4)
      let nameLength = try data.zarrInteger(cursor + 28, 2)
      let extraLength = try data.zarrInteger(cursor + 30, 2)
      let commentLength = try data.zarrInteger(cursor + 32, 2)
      var offset = try data.zarrInteger(cursor + 42, 4)
      let next = cursor + 46 + nameLength + extraLength + commentLength
      guard next <= directoryEnd,
            let name = String(data: try data.zarrSlice(cursor + 46, nameLength), encoding: .utf8) else {
        throw ZarrImportError.invalid("ZIP entry name or length")
      }
      var extra = cursor + 46 + nameLength
      let extraEnd = extra + extraLength
      while extra < extraEnd {
        let tag = try data.zarrInteger(extra, 2)
        let length = try data.zarrInteger(extra + 2, 2)
        extra += 4
        guard length <= extraEnd - extra else { throw ZarrImportError.invalid("ZIP extra field") }
        if tag == 1 {
          var position = extra
          func field() throws -> Int {
            guard position <= extra + length - 8 else { throw ZarrImportError.invalid("ZIP64 extra field") }
            defer { position += 8 }
            return try data.zarrInteger(position, 8)
          }
          if decoded == Int(UInt32.max) { decoded = try field() }
          if compressed == Int(UInt32.max) { compressed = try field() }
          if offset == Int(UInt32.max) { offset = try field() }
        }
        extra += length
      }
      if !name.hasSuffix("/") {
        guard Self.validKey(name), members[name] == nil, offset <= start, compressed <= start - offset else {
          throw ZarrImportError.invalid("unsafe, duplicate, or out-of-range ZIP entry")
        }
        members[name] = Member(offset: offset, compressed: compressed, decoded: decoded, crc: crc, method: method, flags: flags)
      }
      cursor = next
    }
    guard cursor == directoryEnd else { throw ZarrImportError.invalid("ZIP directory length mismatch") }
  }
}

enum ZarrCompression {
  static func inflate(_ data: Data, size: Int, windowBits: Int32) throws -> Data {
    guard (0...ZarrStore.maximumChunkBytes).contains(size), data.count <= Int(UInt32.max) else {
      throw ZarrImportError.invalid("compressed chunk exceeds limit")
    }
    var result = Data(count: size + 1)
    var stream = z_stream()
    guard inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
      throw ZarrImportError.invalid("could not initialize DEFLATE")
    }
    defer { inflateEnd(&stream) }
    let status = data.withUnsafeBytes { source in
      result.withUnsafeMutableBytes { target in
        stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: UInt8.self).baseAddress)
        stream.avail_in = uInt(source.count)
        stream.next_out = target.bindMemory(to: UInt8.self).baseAddress
        stream.avail_out = uInt(target.count)
        return zlib.inflate(&stream, Z_FINISH)
      }
    }
    guard status == Z_STREAM_END, stream.total_out == size, stream.avail_in == 0 else {
      throw ZarrImportError.invalid("DEFLATE data or decoded size")
    }
    result.removeLast()
    return result
  }

  static func crc32c(_ data: Data) -> UInt32 {
    var crc = UInt32.max
    for byte in data {
      crc ^= UInt32(byte)
      for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1 == 0) ? 0 : 0x82f63b78) }
    }
    return ~crc
  }
}

extension Data {
  func zarrSlice(_ offset: Int, _ length: Int) throws -> Data {
    guard offset >= 0, length >= 0, offset <= count, length <= count - offset else {
      throw ZarrImportError.invalid("truncated binary data")
    }
    return subdata(in: offset..<(offset + length))
  }
  func zarrUInt64(_ offset: Int) throws -> UInt64 {
    let bytes = try zarrSlice(offset, 8)
    return bytes.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
  }
  func zarrInteger(_ offset: Int, _ length: Int) throws -> Int {
    let bytes = try zarrSlice(offset, length)
    var value: UInt64 = 0
    for (i, byte) in bytes.enumerated() { value |= UInt64(byte) << (8 * i) }
    guard value <= UInt64(Int.max) else { throw ZarrImportError.invalid("integer exceeds addressable size") }
    return Int(value)
  }
}
