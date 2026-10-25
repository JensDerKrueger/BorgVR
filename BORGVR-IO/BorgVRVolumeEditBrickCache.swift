import Foundation
import Compression
import CryptoKit

/// Disposable brick data plus a compact table of contents at EOF.
/// The journal remains authoritative; an unclean file can rebuild its TOC.
final class BorgVRVolumeEditBrickCache {
  struct Record {
    let index: Int
    let revision: UInt64
    let componentRanges: [BORGVRComponentRange]
    let original: Bool
    let rawByteCount: Int
    let compressed: Bool
    let payload: Data

    func materializedBrick() throws -> BorgVRMaterializedEditBrick? {
      guard !original else { return nil }
      var bytes: [UInt8]
      if compressed {
        bytes = [UInt8](repeating: 0, count: rawByteCount)
        let count = bytes.withUnsafeMutableBufferPointer { output in
          payload.withUnsafeBytes { input in
            compression_decode_buffer(output.baseAddress!, rawByteCount,
              input.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_LZ4)
          }
        }
        guard count == rawByteCount else { throw BorgVRVolumeEditError.corruptJournal }
      } else { bytes = Array(payload) }
      return .init(index: index, revision: revision, bytes: bytes,
        componentRanges: componentRanges, matchesOriginal: false)
    }
  }

  struct Summary {
    let revision: UInt64
    let matchesOriginal: Bool
    let metadata: BrickMetadata
  }

  private struct Entry {
    var offset: UInt64
    let length: Int
    let index: Int
    let revision: UInt64
    let rawByteCount: Int
    let storedByteCount: Int
    let flags: UInt64
    let digest: Data
    let ranges: [BORGVRComponentRange]
    var original: Bool { flags & 1 != 0 }
    var compressed: Bool { flags & 2 != 0 }
    var summary: Summary {
      .init(revision: revision, matchesOriginal: original,
        metadata: .init(offset: 0, size: rawByteCount,
          minValue: ranges.lazy.map(\.minValue).min() ?? 0,
          maxValue: ranges.lazy.map(\.maxValue).max() ?? 0, componentRanges: ranges))
    }
    var payloadOffset: UInt64 { offset + UInt64(BorgVRVolumeEditBrickCache.recordHeaderSize + ranges.count * 16) }
  }

  private struct Reader {
    let data: Data
    var offset = 0
    var remaining: Int { data.count - offset }
    mutating func bytes(_ count: Int) throws -> Data {
      guard count >= 0, count <= remaining else { throw BorgVRVolumeEditError.corruptJournal }
      defer { offset += count }
      return data.subdata(in: offset..<(offset + count))
    }
    mutating func integer() throws -> UInt64 {
      guard remaining >= 8 else { throw BorgVRVolumeEditError.corruptJournal }
      defer { offset += 8 }
      return data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
    }
    mutating func count(maximum: Int) throws -> Int {
      let value = try integer()
      guard value <= UInt64(maximum) else { throw BorgVRVolumeEditError.corruptJournal }
      return Int(value)
    }
  }

  private let lock = NSLock()
  private let url: URL
  private var handle: FileHandle?
  private var header: Data
  private var entries: [Int: Entry] = [:]
  private var dataEnd: UInt64
  private var tableDirty = false
  private var hasStoredTable = false
  private var needsRecovery = false
  private(set) var openedUsingTableOfContents = false
  private(set) var recoveredRecordCount = 0
  private static let maximumRecordSize = 256 * 1024 * 1024
  private static let recordMagic = Data("BVBRK02\n".utf8)
  private static let tableMagic = Data("BVTOC02\n".utf8)
  private static let footerMagic = Data("BVEND02\n".utf8)
  private static let footerSize = 56
  private static let recordHeaderSize = 96

  init(url: URL, editStateID: UUID) throws {
    self.url = url
    var id = editStateID.uuid
    var header = Data("BVREC02\n".utf8)
    header.append(0) // in-place compaction in progress
    withUnsafeBytes(of: &id) { header.append(contentsOf: $0) }
    self.header = header
    dataEnd = UInt64(header.count)
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    let handle = try FileHandle(forUpdating: url)
    self.handle = handle
    do {
      let actual = try handle.read(upToCount: header.count) ?? Data()
      guard actual == header else { throw BorgVRVolumeEditError.corruptJournal }
      self.header = actual
      let size = try handle.seekToEnd()
      if (try? loadTable(fileSize: size)) == true {
        openedUsingTableOfContents = true
      } else {
        try recoverRecords(fileSize: size)
        try writeTable()
      }
    } catch {
      // No edits are lost: mask + original reconstruct this disposable file.
      entries.removeAll()
      dataEnd = UInt64(header.count)
      self.header = header
      try handle.truncate(atOffset: 0)
      try handle.seek(toOffset: 0)
      try handle.write(contentsOf: header)
      try handle.synchronize()
      tableDirty = true
    }
  }

  deinit {
    try? synchronize()
    try? handle?.close()
  }

  private func openStorage() throws -> FileHandle {
    if let handle { return handle }
    if FileManager.default.fileExists(atPath: url.path) {
      let file = try FileHandle(forUpdating: url)
      handle = file
      return file
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard FileManager.default.createFile(atPath: url.path, contents: header) else { throw BorgVRVolumeEditError.corruptJournal }
    let file = try FileHandle(forUpdating: url)
    handle = file
    dataEnd = UInt64(header.count)
    tableDirty = true
    return file
  }

  func summary(index: Int, revision: UInt64) -> Summary? {
    lock.withLock {
      guard !needsRecovery, let entry = entries[index], entry.revision == revision else { return nil }
      return entry.summary
    }
  }

  func storedBrick(index: Int, revision: UInt64) throws -> Record? {
    try lock.withLock {
      guard !needsRecovery else { throw BorgVRVolumeEditError.corruptJournal }
      guard let entry = entries[index], entry.revision == revision, let handle else { return nil }
      do {
        try handle.seek(toOffset: entry.payloadOffset)
        let payload = try readExactly(entry.storedByteCount)
        guard Self.digest(payload) == entry.digest else { throw BorgVRVolumeEditError.corruptJournal }
        return Record(index: entry.index, revision: entry.revision, componentRanges: entry.ranges,
          original: entry.original, rawByteCount: entry.rawByteCount, compressed: entry.compressed, payload: payload)
      } catch BorgVRVolumeEditError.corruptJournal {
        entries[index] = nil
        tableDirty = true
        throw BorgVRVolumeEditError.corruptJournal
      }
    }
  }

  func brick(index: Int, revision: UInt64) throws -> BorgVRMaterializedEditBrick? {
    try storedBrick(index: index, revision: revision)?.materializedBrick()
  }

  /// Renderer reads decode directly into its reusable upload buffer.
  func readBrick(index: Int, revision: UInt64, into output: UnsafeMutablePointer<UInt8>, byteCount: Int) throws -> Summary? {
    guard let record = try storedBrick(index: index, revision: revision), !record.original else { return nil }
    guard byteCount > 0, record.rawByteCount == byteCount else { throw BorgVRVolumeEditError.invalidBufferSize }
    if record.compressed {
      let decoded = record.payload.withUnsafeBytes { input in
        compression_decode_buffer(output, byteCount, input.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_LZ4)
      }
      guard decoded == byteCount else { throw BorgVRVolumeEditError.corruptJournal }
    } else {
      _ = record.payload.withUnsafeBytes { memcpy(output, $0.baseAddress!, byteCount) }
    }
    return .init(revision: revision, matchesOriginal: false,
      metadata: .init(offset: 0, size: byteCount,
        minValue: record.componentRanges.lazy.map(\.minValue).min() ?? 0,
        maxValue: record.componentRanges.lazy.map(\.maxValue).max() ?? 0, componentRanges: record.componentRanges))
  }

  func synchronize() throws {
    try lock.withLock {
      guard !needsRecovery else { throw BorgVRVolumeEditError.corruptJournal }
      try writeTable()
      try handle?.synchronize()
    }
  }

  func closeStorage() throws {
    try lock.withLock {
      guard !needsRecovery else { throw BorgVRVolumeEditError.corruptJournal }
      try writeTable()
      try handle?.close()
      handle = nil
    }
  }

  func store(_ brick: BorgVRMaterializedEditBrick, synchronize: Bool = true) throws {
    try lock.withLock {
      guard !needsRecovery else { throw BorgVRVolumeEditError.corruptJournal }
      guard brick.index >= 0, brick.bytes.count <= Self.maximumRecordSize,
        brick.componentRanges.count <= BORGVRMetaData.maximumComponentCount,
        brick.componentRanges.allSatisfy({ $0.minValue >= 0 && $0.maxValue >= $0.minValue }) else {
        throw BorgVRVolumeEditError.invalidBufferSize
      }
      if entries[brick.index].map({ $0.revision > brick.revision }) == true { return }
      var payload = brick.matchesOriginal ? Data() : Data(brick.bytes)
      var compressed = false
      if !payload.isEmpty {
        var output = [UInt8](repeating: 0, count: payload.count)
        let count = output.withUnsafeMutableBufferPointer { destination in
          payload.withUnsafeBytes { input in
            compression_encode_buffer(destination.baseAddress!, destination.count,
              input.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_LZ4)
          }
        }
        if count > 0 && count < payload.count { payload = Data(output.prefix(count)); compressed = true }
      }
      let flags: UInt64 = (brick.matchesOriginal ? 1 : 0) | (compressed ? 2 : 0)
      let file = try openStorage()
      let entry = Entry(offset: dataEnd,
        length: Self.recordHeaderSize + brick.componentRanges.count * 16 + payload.count,
        index: brick.index, revision: brick.revision, rawByteCount: brick.matchesOriginal ? 0 : brick.bytes.count,
        storedByteCount: payload.count, flags: flags, digest: Self.digest(payload), ranges: brick.componentRanges)
      do {
        // Overwrite only the old TOC, never previously stored brick payloads.
        if hasStoredTable { try file.truncate(atOffset: dataEnd); hasStoredTable = false }
        tableDirty = true
        try file.seek(toOffset: dataEnd)
        try file.write(contentsOf: Self.recordMagic + Self.encodeEntry(entry))
        try file.write(contentsOf: payload)
        if synchronize { try file.synchronize() }
        entries[brick.index] = entry
        dataEnd += UInt64(entry.length)
      } catch { needsRecovery = true; throw error }
    }
  }

  func compact() throws {
    try lock.withLock {
      guard let handle else { return }
      guard !needsRecovery else { throw BorgVRVolumeEditError.corruptJournal }
      needsRecovery = true
      try handle.seek(toOffset: 8)
      try handle.write(contentsOf: Data([1]))
      try handle.synchronize()
      var destination = UInt64(header.count)
      var compacted: [Int: Entry] = [:]
      for (index, entry) in entries.sorted(by: { $0.value.offset < $1.value.offset }) {
        try handle.seek(toOffset: entry.offset)
        let frame = try readExactly(entry.length)
        // A whole frame is read before its ranges can overlap the destination.
        try handle.seek(toOffset: destination)
        try handle.write(contentsOf: frame)
        var relocated = entry
        relocated.offset = destination
        compacted[index] = relocated
        destination += UInt64(entry.length)
      }
      entries = compacted
      dataEnd = destination
      tableDirty = true
      try handle.truncate(atOffset: dataEnd)
      hasStoredTable = false
      try writeTable()
      try handle.seek(toOffset: 0)
      try handle.write(contentsOf: header)
      try handle.synchronize()
      needsRecovery = false
    }
  }

  /// Does not write a TOC: callers are about to remove these files.
  func closeForRemoval() throws {
    try lock.withLock {
      try handle?.close()
      handle = nil
      entries.removeAll()
      dataEnd = UInt64(header.count)
      tableDirty = false
      hasStoredTable = false
      needsRecovery = false
    }
  }

  func compactIfNeeded() throws {
    let needed = lock.withLock {
      let live = UInt64(header.count + entries.values.reduce(0) { $0 + $1.length })
      return handle != nil && dataEnd > live && dataEnd - live > max(16 * 1024 * 1024, dataEnd / 3)
    }
    if needed { try compact() } else { try synchronize() }
  }

  private func loadTable(fileSize: UInt64) throws -> Bool {
    guard let handle, fileSize >= UInt64(header.count + Self.footerSize) else { return false }
    try handle.seek(toOffset: fileSize - UInt64(Self.footerSize))
    var footer = Reader(data: try readExactly(Self.footerSize))
    guard try footer.bytes(8) == Self.footerMagic else { return false }
    let offset = try footer.integer()
    let length = try footer.count(maximum: Self.maximumRecordSize)
    let digest = try footer.bytes(32)
    guard offset >= UInt64(header.count), offset <= fileSize - UInt64(Self.footerSize),
      UInt64(length) == fileSize - UInt64(Self.footerSize) - offset else { return false }
    try handle.seek(toOffset: offset)
    let table = try readExactly(length)
    guard Self.digest(table) == digest else { return false }
    var reader = Reader(data: table)
    guard try reader.bytes(8) == Self.tableMagic else { return false }
    let count = try reader.count(maximum: reader.remaining / Self.recordHeaderSize)
    var loaded: [Int: Entry] = [:]
    loaded.reserveCapacity(count)
    var previousEnd = UInt64(header.count)
    for _ in 0..<count {
      let position = try reader.integer()
      let entry = try Self.decodeEntry(&reader, offset: position)
      guard loaded[entry.index] == nil, position >= previousEnd, position <= offset,
        UInt64(entry.length) <= offset - position else { return false }
      loaded[entry.index] = entry
      previousEnd = position + UInt64(entry.length)
    }
    guard reader.remaining == 0 else { return false }
    entries = loaded
    dataEnd = offset
    tableDirty = false
    hasStoredTable = true
    return true
  }

  private func writeTable() throws {
    guard let handle, tableDirty else { return }
    var table = Self.tableMagic
    Self.appendInteger(UInt64(entries.count), to: &table)
    for entry in entries.values.sorted(by: { $0.offset < $1.offset }) {
      Self.appendInteger(entry.offset, to: &table)
      table.append(Self.encodeEntry(entry))
    }
    guard table.count <= Self.maximumRecordSize else { throw BorgVRVolumeEditError.invalidBufferSize }
    var footer = Self.footerMagic
    Self.appendInteger(dataEnd, to: &footer)
    Self.appendInteger(UInt64(table.count), to: &footer)
    footer.append(Self.digest(table))
    try handle.seek(toOffset: dataEnd)
    try handle.write(contentsOf: table)
    try handle.write(contentsOf: footer)
    try handle.truncate(atOffset: dataEnd + UInt64(table.count + footer.count))
    try handle.synchronize()
    tableDirty = false
    hasStoredTable = true
  }

  private func recoverRecords(fileSize: UInt64) throws {
    guard let handle else { return }
    entries.removeAll()
    var offset = UInt64(header.count)
    while fileSize - min(fileSize, offset) >= 8 {
      try handle.seek(toOffset: offset)
      let magic = try readExactly(8)
      guard magic == Self.recordMagic else { break }
      let entry: Entry
      do {
        let fixed = try readExactly(Self.recordHeaderSize - 8)
        var fixedReader = Reader(data: fixed)
        // Range count is the last integer, before the 32-byte digest.
        fixedReader.offset = 48
        let rangeCount = try fixedReader.count(maximum: BORGVRMetaData.maximumComponentCount)
        let ranges = try readExactly(rangeCount * 16)
        var reader = Reader(data: fixed + ranges)
        entry = try Self.decodeEntry(&reader, offset: offset)
        guard UInt64(entry.length) <= fileSize - offset else { break }
        let payload = try readExactly(entry.storedByteCount)
        guard Self.digest(payload) == entry.digest else { break }
      } catch { break }
      if entries[entry.index].map({ $0.revision > entry.revision }) != true { entries[entry.index] = entry }
      recoveredRecordCount += 1
      offset += UInt64(entry.length)
    }
    dataEnd = offset
    try handle.truncate(atOffset: dataEnd)
    hasStoredTable = false
    tableDirty = true
  }

  private func readExactly(_ count: Int) throws -> Data {
    guard let handle, let data = try handle.read(upToCount: count), data.count == count else {
      if count == 0 { return Data() }
      throw BorgVRVolumeEditError.corruptJournal
    }
    return data
  }

  private static func encodeEntry(_ entry: Entry) -> Data {
    var data = Data()
    for value in [UInt64(entry.length), UInt64(entry.index), entry.revision, UInt64(entry.rawByteCount),
                  UInt64(entry.storedByteCount), entry.flags, UInt64(entry.ranges.count)] {
      appendInteger(value, to: &data)
    }
    data.append(entry.digest)
    for range in entry.ranges {
      appendInteger(UInt64(range.minValue), to: &data); appendInteger(UInt64(range.maxValue), to: &data)
    }
    return data
  }

  private static func decodeEntry(_ reader: inout Reader, offset: UInt64) throws -> Entry {
    let length = try reader.count(maximum: maximumRecordSize + recordHeaderSize + BORGVRMetaData.maximumComponentCount * 16)
    let index = try reader.count(maximum: Int.max)
    let revision = try reader.integer()
    let raw = try reader.count(maximum: maximumRecordSize)
    let stored = try reader.count(maximum: maximumRecordSize)
    let flags = try reader.integer()
    let components = try reader.count(maximum: BORGVRMetaData.maximumComponentCount)
    let digest = try reader.bytes(32)
    guard components <= reader.remaining / 16, flags & ~3 == 0,
      flags & 1 == 0 || (raw == 0 && stored == 0),
      flags & 2 == 0 ? raw == stored : (stored > 0 && stored < raw) else { throw BorgVRVolumeEditError.corruptJournal }
    var ranges: [BORGVRComponentRange] = []
    for _ in 0..<components {
      let low = try reader.count(maximum: Int.max), high = try reader.count(maximum: Int.max)
      guard high >= low else { throw BorgVRVolumeEditError.corruptJournal }
      ranges.append(.init(minValue: low, maxValue: high))
    }
    guard length == recordHeaderSize + components * 16 + stored else {
      throw BorgVRVolumeEditError.corruptJournal
    }
    return Entry(offset: offset, length: length, index: index, revision: revision, rawByteCount: raw,
      storedByteCount: stored, flags: flags, digest: digest, ranges: ranges)
  }

  private static func appendInteger(_ value: UInt64, to data: inout Data) {
    var encoded = value.littleEndian
    withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
  }
  private static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
}
