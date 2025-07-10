import Foundation
import Compression
import Network

/**
 A caching remote data source that retrieves and locally caches volume bricks
 from a remote source.

 This class wraps a RemoteDataSource and uses a memory‐mapped file to cache
 volume bricks. It supports both synchronous and asynchronous brick requests,
 and manages a background worker to fetch uncached bricks. If compression is
 enabled, it decompresses brick data on demand.
 */
final class CachingRemoteDataSource: DataSource {

  // MARK: - Properties

  /// The remote data source used to fetch volume bricks.
  private let remoteDataSource: RemoteDataSource

  /// The target filename for the cached local data.
  let targetFilename: String

  /// Flag to indicate if bricks should be fetched asynchronously.
  private let asyncGet: Bool

  /// An optional logger for debug and error messages.
  private let logger: LoggerBase?

  /// Flag indicating if caching has been fully completed.
  private(set) var cachingComplete: Bool = false

  /// A map tracking which bricks have been cached.
  private(set) var cacheMap: CacheMap

  /// The memory‐mapped file used to store cached brick data.
  private var dataFile: MemoryMappedFile

  /// Scratch buffer for decompression (if compression is enabled).
  private var compressionScratchBuffer: UnsafeMutableRawPointer?

  /// Temporary buffer for brick data (used during synchronous fetches).
  private var tempDataBuffer: UnsafeMutablePointer<UInt8>

  /// Temporary buffer for background brick fetches.
  private var tempDataBufferBackground: UnsafeMutablePointer<UInt8>

  /// The full size of a brick in bytes.
  private var fullBrickSize: Int

  /// A background dispatch queue for caching work.
  private let workerQueue = DispatchQueue(label: "CachingWorkerQueue", qos: .background)

  /// The background worker task.
  private var workerTask: DispatchWorkItem?

  /// A queue of brick indices requested for caching.
  private var requestQueue = [Int]()

  /// A lock for synchronizing access to the request queue.
  private let requestQueueLock = DispatchQueue(label: "RequestQueueLock")

  /// A semaphore used to signal the worker that new requests are available.
  private let requestSemaphore = DispatchSemaphore(value: 0)

  /// A dictionary mapping brick indices to semaphores waiting for their fetch.
  private var waiters: [Int: DispatchSemaphore] = [:]

  /// Flag indicating if the background worker has been terminated.
  private var terminated = false

  /// The current caching progress as a value between 0 and 1.
  public var cachingProgress: Double {
    Double(cacheMap.setCount) / Double(cacheMap.count)
  }

  // MARK: - Initialization

  /**
   Initializes a new CachingRemoteDataSource.

   This initializer creates a RemoteDataSource for the given connection and dataset ID.
   It then loads or creates a cache map, sets up the backing memory‐mapped file, and
   allocates buffers for decompression if needed. Finally, it starts a background worker
   to fetch uncached bricks.

   - Parameters:
   - connection: The NWConnection used for remote communication.
   - datasetID: The identifier of the remote dataset.
   - asyncGet: A Boolean indicating if asynchronous brick fetching is enabled.
   - filename: The target filename for the local cache.
   - Throws: An error if the backing file cannot be created or mapped.
   */
  init(connection: NWConnection, datasetID: Int, asyncGet: Bool,
       filename: String, logger: LoggerBase?) throws {
    self.remoteDataSource = try RemoteDataSource(connection: connection,
                                                 datasetID: datasetID,
                                                 logger:logger)
    self.targetFilename = filename
    self.asyncGet = asyncGet
    self.logger = logger

    let metadata = remoteDataSource.getMetadata()
    let fileManager = FileManager.default
    let fullURL = URL(fileURLWithPath: targetFilename)

    // Load or create cache map.
    let cacheMapURL = fullURL.appendingPathExtension("cachemap")
    if fileManager.fileExists(atPath: cacheMapURL.path) {
      self.cacheMap = try CacheMap(fromFile: cacheMapURL)
      if self.cacheMap.count != metadata.brickMetadata.count {
        self.cacheMap = CacheMap(count: metadata.brickMetadata.count)
      }
      logger?.dev("Using existing cache map, continuing caching...")
    } else {
      self.cacheMap = CacheMap(count: metadata.brickMetadata.count)
      logger?.dev("Creating new cache map...")
    }

    // Load or create backing file.
    let incompleteFilename = filename + ".incomplete"
    let fileURL = URL(fileURLWithPath: incompleteFilename)
    if fileManager.fileExists(atPath: fileURL.path) {
      self.dataFile = try MemoryMappedFile(filename: incompleteFilename, readOnly: false)
    } else {
      let lastBrick = metadata.brickMetadata.last!
      let fileSize = Int64(lastBrick.offset + lastBrick.size)
      self.dataFile = try MemoryMappedFile(filename: incompleteFilename, size: fileSize)

      // Store the file size at the beginning of the file.
      let pointer = self.dataFile.mappedMemory.assumingMemoryBound(to: UInt64.self)
      pointer[0] = UInt64(fileSize)
    }

    // Decompression setup.
    self.fullBrickSize = metadata.brickSize * metadata.brickSize * metadata.brickSize *
    metadata.componentCount * metadata.bytesPerComponent
    if metadata.compression {
      let scratchBufferSize = compression_decode_scratch_buffer_size(COMPRESSION_LZ4)
      self.compressionScratchBuffer = UnsafeMutableRawPointer.allocate(
        byteCount: scratchBufferSize,
        alignment: MemoryLayout<UInt8>.alignment
      )
    }
    self.tempDataBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: fullBrickSize)
    self.tempDataBufferBackground = UnsafeMutablePointer<UInt8>.allocate(capacity: fullBrickSize)

    // Initialize the request queue (initially empty).
    self.requestQueue = []

    // Start background worker.
    let task = DispatchWorkItem { [weak self] in
      self?.backgroundWorkerLoop()
    }
    self.workerTask = task
    workerQueue.async(execute: task)

    logger?.dev("CachingRemoteDataSource initialized")
  }

  // MARK: - Worker Control

  /**
   Stops the background worker.

   This method signals termination, cancels the worker task, and wakes the worker if it is waiting.
   */
  func stopWorker() {
    terminated = true
    workerTask?.cancel()
    requestSemaphore.signal() // Wake worker if waiting.
    workerQueue.sync(flags: .barrier) {}
  }

  deinit {
    stopWorker()
    let cacheMapURL = URL(fileURLWithPath: targetFilename).appendingPathExtension("cachemap")
    if cachingComplete {
      let incompleteFilename = targetFilename + ".incomplete"
      let fileManager = FileManager.default
      let incompleteURL = URL(fileURLWithPath: incompleteFilename)
      let completeURL = URL(fileURLWithPath: targetFilename)

      do {
        try self.dataFile.close()
        if fileManager.fileExists(atPath: completeURL.path()) {
          try FileManager.default.removeItem(at: completeURL)
        }
        try fileManager.moveItem(at: incompleteURL, to: completeURL)
        remoteDataSource.getMetadata().datasetDescription = "Local copy of \(remoteDataSource.getMetadata().datasetDescription)"
        try remoteDataSource.getMetadata().save(filename: targetFilename)
        try? FileManager.default.removeItem(at: cacheMapURL)
        logger?.dev("Dataset caching complete, finalized local copy")
      } catch {
        logger?.error("Error while completing dataset caching: \(error)")
      }
    } else {
      try? cacheMap.save(to: cacheMapURL)
      logger?.dev("Dataset caching incomplete, caching will continue later")
    }

    compressionScratchBuffer?.deallocate()
    tempDataBuffer.deallocate()
    tempDataBufferBackground.deallocate()

    logger?.dev("CachingRemoteDataSource deinitialized")
  }

  // MARK: - Brick Access Methods

  /**
   Retrieves the first (lowest resolution) brick and writes its data into the output buffer.
   In contrast to getBrick, this call is always synchronous.

   - Parameter outputBuffer: A pointer to a memory area with capacity at least the brick size.
   - Throws: An error if the brick cannot be retrieved.
   */
  func getFirstBrick(outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    let minResBrick = remoteDataSource.getMetadata().brickMetadata.count - 1
    try getBrick(index: minResBrick, outputBuffer: outputBuffer, asyncGet: false)
  }

  /**
   Retrieves a brick at the specified index and writes its data into the output buffer.

   This method uses the asyncGet flag to determine if the brick should be fetched
   asynchronously.

   - Parameters:
   - index: The index of the brick to retrieve.
   - outputBuffer: A pointer to a memory area with capacity at least the brick size.
   - Throws: An error if the brick is not yet available or cannot be retrieved.
   */
  func getBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    try getBrick(index: index, outputBuffer: outputBuffer, asyncGet: self.asyncGet)
  }

  /**
   Retrieves a brick at the specified index, with control over asynchronous fetching.

   If the brick is already cached, it is retrieved from local storage. If asyncGet is true and
   the brick is not available, an error is thrown. Otherwise, the method waits until the brick
   becomes available.

   - Parameters:
   - index: The index of the brick.
   - outputBuffer: A pointer to a memory area with capacity at least the brick size.
   - asyncGet: A Boolean flag indicating if the fetch should be asynchronous.
   - Throws: A BORGVRDataError if the brick is not yet available or retrieval fails.
   */
  func getBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>,
                asyncGet: Bool) throws {
    if cachingComplete || cacheMap.isSet(index: index) {
      try getLocalBrick(index: index, outputBuffer: outputBuffer)
      return
    }

    if asyncGet {
      requestQueueLock.sync {
        requestQueue.append(index)
      }
      requestSemaphore.signal()
      throw BORGVRDataError.brickNotYetAvailable(index: index)
    } else {
      let semaphore = DispatchSemaphore(value: 0)
      requestQueueLock.sync {
        waiters[index] = semaphore
        requestQueue.append(index)
      }
      requestSemaphore.signal()
      semaphore.wait()
      try getLocalBrick(index: index, outputBuffer: outputBuffer)
    }
  }

  func newRequest() {
    requestQueueLock.sync {
      requestQueue.removeAll()
    }
  }


  // MARK: - Background Worker

  /**
   The main loop of the background worker.

   This loop continuously processes brick requests from the requestQueue or prefetches
   uncached bricks. It fetches brick data from the remote source, caches it locally, and
   signals any waiting threads.
   */
  private func backgroundWorkerLoop() {
    while !terminated {
      var indexToProcess: Int?

      // First: priority requests from getBrick unless we have already
      //        cached that brick
      requestQueueLock.sync {
        while !requestQueue.isEmpty {
          indexToProcess = requestQueue.removeFirst()
          guard let nextIndex = indexToProcess else { break }
          if !cacheMap.isSet(index: nextIndex) {
            break
          }
        }
      }

      // Second: background prefetch from cacheMap.
      //         load lower resolutions first
      if indexToProcess == nil && !cacheMap.isComplete() {
        indexToProcess = cacheMap.lastUnsetIndex()
      }

      // Wait if no work is available.
      if indexToProcess == nil {
        requestSemaphore.wait()
        continue
      }

      guard let index = indexToProcess, !cacheMap.isSet(index: index) else { continue }
      do {
        let brickMeta = try remoteDataSource.getRawBrick(
          index: index,
          outputBuffer: tempDataBufferBackground
        )

        try setLocalBrick(index: index, brickMeta: brickMeta)

        requestQueueLock.sync {
          if let waiter = waiters.removeValue(forKey: index) {
            waiter.signal()
          }
        }

        if cacheMap.isComplete() {
          cachingComplete = true
          logger?.dev("All bricks are locally cached")
          break
        }
      } catch {
        // Handle fetch or write failure as needed.
      }
    }
  }

  /**
   Writes the provided brick data into the local memory‐mapped file and updates the cache map.

   - Parameters:
   - index: The index of the brick.
   - brickMeta: The metadata of the brick.
   - Throws: An error if the memory mapping is unavailable.
   */
  private func setLocalBrick(index: Int, brickMeta: BrickMetadata) throws {
    memcpy(
      dataFile.mappedMemory.advanced(by: brickMeta.offset),
      tempDataBufferBackground,
      brickMeta.size
    )
    cacheMap.set(index: index)
  }

  /**
   Retrieves a locally cached brick and decompresses it into the output buffer.

   - Parameters:
   - index: The index of the brick.
   - outputBuffer: A pointer to a memory area to receive the brick data.
   - Throws: An error if the memory mapping is unavailable or decompression fails.
   */
  private func getLocalBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    let brickMeta = getMetadata().brickMetadata[index]
    memcpy(tempDataBuffer, dataFile.mappedMemory.advanced(by: brickMeta.offset), brickMeta.size)
    try decompressRawBrick(inputBuffer: tempDataBuffer, outputBuffer: outputBuffer, brickMeta: brickMeta)
  }

  /**
   Decompresses a raw brick from the input buffer into the output buffer.

   If compression is enabled and the brick size is less than the full brick size,
   the data is decompressed using LZ4. Otherwise, the data is copied directly.

   - Parameters:
   - inputBuffer: The buffer containing the raw brick data.
   - outputBuffer: The buffer to receive the decompressed data.
   - brickMeta: The metadata describing the brick.
   - Throws: A BORGVRDataError if decompression fails or the decompressed size mismatches.
   */
  private func decompressRawBrick(inputBuffer: UnsafeMutablePointer<UInt8>,
                                  outputBuffer: UnsafeMutablePointer<UInt8>,
                                  brickMeta: BrickMetadata) throws {
    if getMetadata().compression && brickMeta.size < fullBrickSize {
      guard let scratchBuffer = compressionScratchBuffer else {
        throw BORGVRDataError.compressionBuffersUnavailable
      }
      let decompressedSize = compression_decode_buffer(
        outputBuffer,
        fullBrickSize,
        inputBuffer,
        brickMeta.size,
        scratchBuffer,
        COMPRESSION_LZ4
      )
      if decompressedSize == 0 {
        throw BORGVRDataError.decompressionFailed
      } else if decompressedSize != fullBrickSize {
        throw BORGVRDataError.decompressedSizeMismatch(expected: fullBrickSize,
                                                       got: decompressedSize)
      }
    } else {
      memcpy(outputBuffer, inputBuffer, fullBrickSize)
    }
  }

  /**
   Returns the metadata from the remote data source.

   - Returns: A BORGVRMetaData object containing the dataset metadata.
   */
  func getMetadata() -> BORGVRMetaData {
    return remoteDataSource.getMetadata()
  }
}

/*
 Copyright (c) 2025 Computer Graphics and Visualization Group, University of Duisburg-Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of this
 software and associated documentation files (the "Software"), to deal in the Software
 without restriction, including without limitation the rights to use, copy, modify,
 merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 permit persons to whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included in all copies or
 substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
 BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT
 OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 DEALINGS IN THE SOFTWARE.
 */
