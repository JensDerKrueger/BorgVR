import Foundation
import zlib

/// ImageVis3D Mobile v1 volumes, either bare .i3m or a ZIP containing one .i3m.
public final class I3MParser: VolumeFileParser {
  public enum Error: Swift.Error, LocalizedError {
    case invalidVolume(String)
    case invalidArchive(String)

    public var errorDescription: String? {
      switch self {
        case .invalidVolume(let reason): return "Invalid IV3Dm volume: \(reason)."
        case .invalidArchive(let reason): return "Unsupported or invalid IV3Dm ZIP archive: \(reason)."
      }
    }
  }

  public let absoluteFilename: String
  public let size: Vec3<Int>
  public let voxelSpacing: Vec3<Float>
  public let bytesPerComponent = 1
  public let components = 1
  public let isLittleEndian = true
  public let offset = 0
  public let dataIsTempCopy = true

  public init(filename: String) throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: filename), options: .mappedIfSafe)
    let temporaryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("borgvr-i3m-\(UUID().uuidString).raw")
    guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    do {
      let output = try FileHandle(forWritingTo: temporaryURL)
      defer { try? output.close() }
      var decoder = VoxelDecoder(output: output)
      if URL(fileURLWithPath: filename).pathExtension.lowercased() == "zip" {
        try Self.decodeArchive(data, into: &decoder)
      } else {
        try data.withUnsafeBytes { bytes in
          for start in stride(from: 0, to: bytes.count, by: Self.chunkSize) {
            try decoder.append(UnsafeRawBufferPointer(rebasing: bytes[start..<min(start + Self.chunkSize, bytes.count)]))
          }
        }
      }
      guard let header = decoder.header, decoder.payloadBytes == header.payloadBytes else {
        throw Error.invalidVolume("truncated header or voxel data")
      }
      try output.close()
      absoluteFilename = temporaryURL.path
      size = header.size
      voxelSpacing = header.voxelSpacing
    } catch {
      try? FileManager.default.removeItem(at: temporaryURL)
      throw error
    }
  }

  private static let chunkSize = 1 << 20

  private struct Header {
    let size: Vec3<Int>
    let voxelSpacing: Vec3<Float>
    let payloadBytes: Int

    init(_ data: Data) throws {
      // Layout from ImageVis3D Mobile's Classes/GLVolume.cpp, loadHeader/loadData:
      // little-endian magic, version, xyz dimensions, xyz relative voxel spacing;
      // then RGBA8 voxels (RGB = encoded gradient, A = scalar), x varying fastest.
      let words = data.withUnsafeBytes { bytes in
        (0..<8).map { UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) }
      }
      guard words[0] == 69426942, words[1] == 1 else {
        throw Error.invalidVolume("expected an I3M version 1 header")
      }
      size = Vec3(x: Int(words[2]), y: Int(words[3]), z: Int(words[4]))
      var count = 4
      for dimension in [size.x, size.y, size.z] {
        let (product, overflow) = count.multipliedReportingOverflow(by: dimension)
        guard dimension > 0, !overflow else { throw Error.invalidVolume("invalid dimensions") }
        count = product
      }
      payloadBytes = count
      let spacing = words[5...7].map { Double(Float(bitPattern: $0)) }
      guard spacing.allSatisfy({ $0.isFinite && $0 > 0 }) else {
        throw Error.invalidVolume("voxel spacing must be finite and positive")
      }
      let longest = max(spacing[0] * Double(size.x), spacing[1] * Double(size.y), spacing[2] * Double(size.z))
      let normalized = spacing.map { Float($0 / longest) }
      guard normalized.allSatisfy({ $0.isFinite && $0 > 0 }) else {
        throw Error.invalidVolume("voxel spacing cannot be represented")
      }
      // I3M records relative spacing, not a physical unit. Preserve proportions
      // and use a longest extent of one meter, as for PVM imports.
      voxelSpacing = Vec3(x: normalized[0], y: normalized[1], z: normalized[2])
    }
  }

  /// Extracts scalar bytes directly into the intermediate raw file, without
  /// materializing a second, four-times-larger uncompressed I3M file.
  private struct VoxelDecoder {
    let output: FileHandle
    var headerBytes = Data()
    var header: Header?
    var payloadBytes = 0

    mutating func append(_ bytes: UnsafeRawBufferPointer) throws {
      var start = 0
      if header == nil {
        start = min(32 - headerBytes.count, bytes.count)
        headerBytes.append(contentsOf: bytes.prefix(start))
        guard headerBytes.count == 32 else { return }
        header = try Header(headerBytes)
      }
      let count = bytes.count - start
      guard let header, count <= header.payloadBytes - payloadBytes else {
        throw Error.invalidVolume("unexpected bytes after the voxel data")
      }
      let firstScalar = 3 - payloadBytes % 4
      if firstScalar < count {
        let scalarCount = (count - firstScalar - 1) / 4 + 1
        var scalars = Data(count: scalarCount)
        scalars.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
          for i in 0..<scalarCount { target[i] = bytes[start + firstScalar + i * 4] }
        }
        try output.write(contentsOf: scalars)
      }
      payloadBytes += count
    }
  }

  private struct ZIPMember {
    let crc: UInt32
    let compressedBytes: Int
    let uncompressedBytes: Int
    let localOffset: Int
    let method: UInt16
    let flags: UInt16
    let name: Data
  }

  private static func decodeArchive(_ data: Data, into decoder: inout VoxelDecoder) throws {
    try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
      func require(_ offset: Int, _ length: Int) throws {
        guard offset >= 0, length >= 0, offset <= bytes.count, length <= bytes.count - offset else {
          throw Error.invalidArchive("truncated ZIP structure")
        }
      }
      func u16(_ offset: Int) throws -> UInt16 {
        try require(offset, 2)
        return UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
      }
      func u32(_ offset: Int) throws -> UInt32 {
        try require(offset, 4)
        return UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
      }
      guard bytes.count >= 22 else { throw Error.invalidArchive("missing central directory") }
      let end = try stride(from: bytes.count - 22, through: max(0, bytes.count - 22 - 65535), by: -1).first {
        try u32($0) == 0x06054b50 && $0 + 22 + Int(u16($0 + 20)) == bytes.count
      }
      guard let end, try u16(end + 4) == 0, try u16(end + 6) == 0,
            try u16(end + 8) == u16(end + 10) else {
        throw Error.invalidArchive("missing central directory or multi-disk archive")
      }
      let entries = Int(try u16(end + 10))
      let directoryBytes = Int(try u32(end + 12))
      var cursor = Int(try u32(end + 16))
      guard entries != 65535, directoryBytes != Int(UInt32.max), cursor != Int(UInt32.max),
            cursor <= end, directoryBytes == end - cursor else {
        throw Error.invalidArchive("ZIP64 or invalid central directory")
      }
      var member: ZIPMember?
      for _ in 0..<entries {
        try require(cursor, 46)
        guard try u32(cursor) == 0x02014b50 else { throw Error.invalidArchive("invalid central directory entry") }
        let nameLength = Int(try u16(cursor + 28))
        let next = cursor + 46 + nameLength + Int(try u16(cursor + 30)) + Int(try u16(cursor + 32))
        guard next <= end else { throw Error.invalidArchive("truncated central directory entry") }
        let name = Data(bytes[(cursor + 46)..<(cursor + 46 + nameLength)])
        let path = String(decoding: name, as: UTF8.self)
        if path.lowercased().hasSuffix(".i3m"), !path.hasPrefix("__MACOSX/"),
           !path.split(separator: "/").contains(where: { $0.hasPrefix("._") }) {
          guard member == nil else {
            throw Error.invalidArchive("contains multiple I3M volumes; import each .i3m separately")
          }
          guard try u16(cursor + 34) == 0 else { throw Error.invalidArchive("multi-disk archive") }
          member = ZIPMember(crc: try u32(cursor + 16),
            compressedBytes: Int(try u32(cursor + 20)), uncompressedBytes: Int(try u32(cursor + 24)),
            localOffset: Int(try u32(cursor + 42)), method: try u16(cursor + 10),
            flags: try u16(cursor + 8), name: name)
        }
        cursor = next
      }
      guard cursor == end, let member else { throw Error.invalidArchive("no I3M volume found") }
      guard member.flags & 0x41 == 0, member.method == 0 || member.method == 8,
            member.compressedBytes != Int(UInt32.max), member.uncompressedBytes != Int(UInt32.max),
            member.localOffset != Int(UInt32.max) else {
        throw Error.invalidArchive("encrypted, ZIP64, or unsupported compression")
      }
      let local = member.localOffset
      try require(local, 30)
      guard try u32(local) == 0x04034b50, try u16(local + 6) == member.flags,
            try u16(local + 8) == member.method else { throw Error.invalidArchive("invalid local header") }
      let nameLength = Int(try u16(local + 26))
      let payload = local + 30 + nameLength + Int(try u16(local + 28))
      let directoryStart = Int(try u32(end + 16))
      guard payload <= directoryStart, member.compressedBytes <= directoryStart - payload else {
        throw Error.invalidArchive("invalid member size")
      }
      guard Data(bytes[(local + 30)..<(local + 30 + nameLength)]) == member.name else {
        throw Error.invalidArchive("inconsistent member name")
      }
      var checksum: uLong = 0
      var decodedBytes = 0
      func consume(_ chunk: UnsafeRawBufferPointer) throws {
        guard chunk.count <= member.uncompressedBytes - decodedBytes else {
          throw Error.invalidArchive("incorrect uncompressed size")
        }
        checksum = crc32(checksum, chunk.bindMemory(to: UInt8.self).baseAddress, uInt(chunk.count))
        decodedBytes += chunk.count
        try decoder.append(chunk)
      }
      if member.method == 0 {
        guard member.compressedBytes == member.uncompressedBytes else {
          throw Error.invalidArchive("inconsistent stored member size")
        }
        for start in stride(from: 0, to: member.compressedBytes, by: chunkSize) {
          try consume(UnsafeRawBufferPointer(rebasing: bytes[(payload + start)..<(payload + min(start + chunkSize, member.compressedBytes))]))
        }
      } else {
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
          throw Error.invalidArchive("could not initialize DEFLATE")
        }
        defer { inflateEnd(&stream) }
        stream.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: UInt8.self).baseAddress!.advanced(by: payload))
        stream.avail_in = uInt(member.compressedBytes)
        var output = [UInt8](repeating: 0, count: chunkSize)
        var status = Z_OK
        repeat {
          try output.withUnsafeMutableBytes { buffer in
            stream.next_out = buffer.bindMemory(to: UInt8.self).baseAddress!
            stream.avail_out = uInt(buffer.count)
            let available = stream.avail_in
            status = inflate(&stream, Z_NO_FLUSH)
            let count = buffer.count - Int(stream.avail_out)
            guard status == Z_OK || status == Z_STREAM_END,
                  status == Z_STREAM_END || count > 0 || stream.avail_in < available else {
              throw Error.invalidArchive("invalid or incomplete DEFLATE stream")
            }
            try consume(UnsafeRawBufferPointer(rebasing: buffer[..<count]))
          }
        } while status != Z_STREAM_END
        guard stream.avail_in == 0 else { throw Error.invalidArchive("trailing compressed data") }
      }
      guard decodedBytes == member.uncompressedBytes, UInt32(checksum) == member.crc else {
        throw Error.invalidArchive("size or CRC checksum mismatch")
      }
    }
  }
}
