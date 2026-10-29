import Darwin
import Foundation
import Metal

/// One immutable allocation shared by CPU rebuilding and GPU restore brushes.
final class BorgVRVolumeOriginalBrick: @unchecked Sendable {
  static func allocationSize(for count: Int) -> Int? {
    let pageSize = Int(getpagesize())
    guard count > 0, count <= Int.max - (pageSize - 1) else { return nil }
    return ((count + pageSize - 1) / pageSize) * pageSize
  }

  private final class Storage: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer
    let length: Int

    init?(copying bytes: UnsafeRawBufferPointer) {
      guard let length = BorgVRVolumeOriginalBrick.allocationSize(for: bytes.count) else { return nil }
      self.length = length
      // Metal's no-copy buffers require a page-aligned, single VM region.
      guard let memory = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
            memory != MAP_FAILED else { return nil }
      pointer = memory
      pointer.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
    }

    deinit { munmap(pointer, length) }
  }

  let count: Int
  var allocatedByteCount: Int { storage.length }
  private let storage: Storage
  private let lock = NSLock()
  private var buffers: [ObjectIdentifier: MTLBuffer] = [:]

  init?(copying bytes: UnsafeRawBufferPointer) {
    guard let storage = Storage(copying: bytes) else { return nil }
    self.storage = storage
    count = bytes.count
  }

  func withUnsafeBytes<Result>(_ body: (UnsafeRawBufferPointer) throws -> Result) rethrows -> Result {
    try withExtendedLifetime(storage) {
      try body(UnsafeRawBufferPointer(start: storage.pointer, count: count))
    }
  }

  func copyBytes(to buffer: UnsafeMutablePointer<UInt8>) {
    withUnsafeBytes { bytes in
      _ = memcpy(buffer, bytes.baseAddress!, bytes.count)
    }
  }

  /// Called only by an active renderer. CPU/background reads never create Metal resources.
  func metalBuffer(device: MTLDevice) -> MTLBuffer? {
    lock.withLock {
      let key = ObjectIdentifier(device)
      if let buffer = buffers[key] { return buffer }
      let storage = self.storage
      guard storage.length <= device.maxBufferLength,
            let buffer = device.makeBuffer(bytesNoCopy: storage.pointer, length: storage.length,
              options: .storageModeShared, deallocator: { [storage] _, _ in
                // Commands retain the buffer. Keep its allocation alive even after
                // cache eviction, without a cycle back to the cached brick object.
                withExtendedLifetime(storage) {}
              }) else { return nil }
      buffers[key] = buffer
      return buffer
    }
  }
}
