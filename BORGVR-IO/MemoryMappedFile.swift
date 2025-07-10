import Foundation
import Darwin

// MARK: - MemoryMappedFile

/**
 A class that encapsulates memory-mapped file access.

 This class opens a file, maps it into memory for efficient I/O operations,
 and provides methods to synchronize, close, and clean up the mapping. It can
 be used for both read-only and read-write access.
 */
public final class MemoryMappedFile {

  // MARK: - Error Type

  /**
   Errors that may occur during memory mapping operations.
   */
  public enum Error: Swift.Error, LocalizedError {
    /// Failed to open the file at the specified path.
    case fileOpenFailed(String)
    /// Failed to retrieve the file size.
    case fileSizeRetrievalFailed
    /// mmap call failed.
    case memoryMappingFailed
    /// Failed to set the file size (e.g., via ftruncate).
    case fileSizeSettingFailed
    /// Failed to close the file descriptor.
    case fileCloseFailed
    /// munmap call failed.
    case memoryUnmappingFailed
    /// msync call failed.
    case msyncFailed

    public var errorDescription: String? {
      switch self {
        case .fileOpenFailed(let filename):
          return "Failed to open the file: \(filename)."
        case .fileSizeRetrievalFailed:
          return "Failed to retrieve file size."
        case .memoryMappingFailed:
          return "Memory mapping failed."
        case .fileSizeSettingFailed:
          return "Failed to set file size."
        case .fileCloseFailed:
          return "Failed to close the file."
        case .memoryUnmappingFailed:
          return "Failed to unmap memory."
        case .msyncFailed:
          return "Failed to sync memory."
      }
    }
  }

  // MARK: - Properties

  /// The file descriptor obtained by opening the file.
  private var fileDescriptor: Int32?
  /// The path of the file.
  public let filename: String
  /// The size of the file in bytes.
  public private(set) var fileSize: Int64
  /// Indicates if the file was opened in read-only mode.
  public private(set) var isReadOnly: Bool
  /// A pointer to the mapped memory region.
  public private(set) var mappedMemory: UnsafeMutableRawPointer

  // MARK: - Initializers

  /**
   Initializes a memory-mapped file for reading or read-write access.

   - Parameters:
   - filename: The path to the file.
   - readOnly: Set to `true` to open the file in read-only mode; otherwise, read-write.
   - Throws: A `MemoryMappedFile.Error` if opening the file, retrieving its size,
   or mapping memory fails.
   */
  public init(filename: String, readOnly: Bool) throws {
    self.filename = filename
    self.isReadOnly = readOnly

    // Open the file in the appropriate mode.
    let openMode = readOnly ? O_RDONLY : O_RDWR
    let descriptor = open(filename, openMode)
    guard descriptor != -1 else {
      throw Error.fileOpenFailed("\(filename) (errno: \(errno): \(String(cString: strerror(errno))) )")
    }
    self.fileDescriptor = descriptor

    // Retrieve file attributes to get the file size.
    var fileStat = stat()
    guard fstat(descriptor, &fileStat) == 0 else {
      Darwin.close(descriptor)
      throw Error.fileSizeRetrievalFailed
    }
    self.fileSize = Int64(fileStat.st_size)

    // Map the file into memory.
    let prot = readOnly ? PROT_READ : (PROT_READ | PROT_WRITE)
    let mapping = mmap(nil, Int(fileSize), prot, MAP_SHARED, descriptor, 0)
    guard mapping != MAP_FAILED else {
      Darwin.close(descriptor)
      throw Error.memoryMappingFailed
    }
    if let mapping = mapping{
      self.mappedMemory = mapping
    } else {
      Darwin.close(descriptor)
      throw Error.memoryMappingFailed
    }
  }

  /**
   Convenience initializer for creating a read-only memory mapping.

   - Parameter filename: The path to the file.
   - Throws: A `MemoryMappedFile.Error` if initialization fails.
   */
  public convenience init(filename: String) throws {
    try self.init(filename: filename, readOnly: true)
  }

  /**
   Initializes a new memory-mapped file by creating (or truncating) the file to the specified size.

   - Parameters:
   - filename: The path to the file.
   - size: The desired file size in bytes.
   - Throws: A `MemoryMappedFile.Error` if creating, truncating, or mapping the file fails.
   */
  public init(filename: String, size: Int64) throws {
    self.filename = filename
    guard size > 0 else { throw Error.fileSizeSettingFailed }
    self.isReadOnly = false
    self.fileSize = size

    // Open (or create) the file with read-write permissions.
    let descriptor = open(filename, O_RDWR | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR)
    guard descriptor != -1 else {
      throw Error.fileOpenFailed(filename)
    }
    self.fileDescriptor = descriptor

    // Set the file size to the desired value.
    guard ftruncate(descriptor, size) == 0 else {
      Darwin.close(descriptor)
      throw Error.fileSizeSettingFailed
    }

    // Map the file into memory with read-write permissions.
    let prot = PROT_READ | PROT_WRITE
    let mapping = mmap(nil, Int(size), prot, MAP_SHARED, descriptor, 0)
    guard mapping != MAP_FAILED else {
      Darwin.close(descriptor)
      throw Error.memoryMappingFailed
    }
    if let mapping = mapping{
      self.mappedMemory = mapping
    } else {
      Darwin.close(descriptor)
      throw Error.memoryMappingFailed
    }
  }

  // MARK: - Methods

  /**
   Synchronizes modifications to the mapped memory back to the file.

   - Throws: A `MemoryMappedFile.Error.msyncFailed` if the msync call fails.
   */
  public func sync() throws {
    guard !isReadOnly else { return }
    if msync(mappedMemory, Int(fileSize), MS_SYNC) != 0 {
      throw Error.msyncFailed
    }
  }

  /**
   Closes the memory-mapped file by unmapping the memory and closing the file descriptor.

   This method attempts to perform all cleanup steps and throws an error if any step fails.

   - Throws: A `MemoryMappedFile.Error` if unmapping or closing the file fails.
   */
  public func close() throws {
    guard fileDescriptor != nil else { return }
    
    var firstError: Error?

    // If the file is writable, attempt to sync memory.
    if !isReadOnly {
      if msync(mappedMemory, Int(fileSize), MS_SYNC) != 0 {
        firstError = firstError ?? Error.msyncFailed
      }
    }

    // Unmap the memory.
    if munmap(mappedMemory, Int(fileSize)) != 0 {
      firstError = firstError ?? Error.memoryUnmappingFailed
    }

    // Close the file descriptor.
    if let descriptor = fileDescriptor {
      if Darwin.close(descriptor) != 0 {
        firstError = firstError ?? Error.fileCloseFailed
      }
      fileDescriptor = nil
    }

    if let error = firstError {
      throw error
    }
  }

  /**
   Ensures that the memory-mapped file is closed when this instance is deallocated.
   */
  deinit {
    try? close()
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
