import Foundation
import Compression
import Network

struct BORGVRLocalDatasetCacheCompletion: Sendable {
  static let notification = Notification.Name("borgvrLocalDatasetCacheDidComplete")

  let datasetID: String
  let fileURL: URL
}

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

  /// An optional logger for debug and error messages.
  private let logger: LoggerBase?

  /// How many bricks do we ant to request in a single call?
  private let maxBricksPerGetRequest: Int

  /// Coordinates worker termination, first-brick waiting, and cache finalization.
  private let lifecycle = CachingRemoteLifecycle()

  /// Flag indicating if caching has been fully completed.
  var cachingComplete: Bool { lifecycle.isCachingComplete }

  /// A map tracking which bricks have been cached.
  private(set) var cacheMap: CacheMap

  /// The memory‐mapped file used to store cached brick data.
  private var dataFile: MemoryMappedFile
  private let dataFileLock = NSLock()
  private let cachedPayloadFileSize: Int64

  /// Scratch buffer for decompression (if compression is enabled).
  private var compressionScratchBuffer: UnsafeMutableRawPointer?

  /// Temporary buffer for brick data (used during synchronous fetches).
  private var tempDataBuffer: UnsafeMutablePointer<UInt8>

  /// Temporary buffer for background brick fetches.
  private var tempDataBufferBackground: UnsafeMutablePointer<UInt8>
  private let backgroundBufferSize: Int

  /// The full size of a brick in bytes.
  private var fullBrickSize: Int

  /// A background dispatch queue for caching work.
  private let workerQueue = DispatchQueue(label: "CachingWorkerQueue", qos: .background)
  private let workerQueueKey = DispatchSpecificKey<Void>()

  /// The background worker task.
  private var workerTask: DispatchWorkItem?

  /// A queue of brick indices requested for caching.
  private var requestQueue = [Int]()

  /// A lock for synchronizing access to the request queue.
  private let requestQueueLock = DispatchQueue(label: "RequestQueueLock")

  /// A semaphore used to signal the worker that new requests are available.
  private let requestSemaphore = DispatchSemaphore(value: 0)

  private var lastFetchFailureLog = Date.distantPast
  private let firstBrickWaitTimeout: TimeInterval = 100

  /// The current caching progress as a value between 0 and 1.
  public var cachingProgress: Double {
    cacheMap.snapshot.fillRatio
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
   - filename: The target filename for the local cache.
   - Throws: An error if the backing file cannot be created or mapped.
   */
  init(connection: NWConnection, datasetID: String, maxBricksPerGetRequest: Int,
       filename: String,
       primaryOrigin: DatasetOrigin,
       connectionTimeout: TimeInterval,
       originProvider: @escaping DatasetOriginProvider,
       authSecret: String? = nil, logger: LoggerBase?) throws {
    self.remoteDataSource = try RemoteDataSource(connection: connection,
                                                 datasetID: datasetID,
                                                 primaryOrigin: primaryOrigin,
                                                 maxBricksPerGetRequest: maxBricksPerGetRequest,
                                                 connectionTimeout: connectionTimeout,
                                                 originProvider: originProvider,
                                                 authSecret: authSecret,
                                                 logger:logger)
    self.targetFilename = filename
    self.logger = logger
    self.maxBricksPerGetRequest = max(1, maxBricksPerGetRequest)

    let metadata = remoteDataSource.getMetadata()
    guard let lastBrick = metadata.brickMetadata.last else {
      throw BORGVRDataError.networkError(message: "Remote dataset contains no bricks.")
    }
    let payloadSize = lastBrick.offset.addingReportingOverflow(lastBrick.size)
    guard !payloadSize.overflow, payloadSize.partialValue > 0 else {
      throw BORGVRDataError.networkError(message: "Remote dataset has an invalid payload size.")
    }
    self.cachedPayloadFileSize = Int64(payloadSize.partialValue)
    let fileManager = FileManager.default
    let fullURL = URL(fileURLWithPath: targetFilename)

    // Load or create cache map.
    let cacheMapURL = fullURL.appendingPathExtension("cachemap")
    if fileManager.fileExists(atPath: cacheMapURL.path) {
      do {
        let loadedMap = try CacheMap(fromFile: cacheMapURL)
        if loadedMap.count == metadata.brickMetadata.count {
          self.cacheMap = loadedMap
        } else {
          self.cacheMap = try CacheMap(count: metadata.brickMetadata.count)
          logger?.warning("Ignoring a cache map whose brick count does not match the dataset.")
        }
      } catch {
        self.cacheMap = try CacheMap(count: metadata.brickMetadata.count)
        logger?.warning("Ignoring a corrupted cache map: \(error.localizedDescription)")
      }
      logger?.dev("Using existing cache map, continuing caching...")
      logger?.dev("\(self.cacheMap.fillRatio * 100) % of bricks are already cached")
    } else {
      self.cacheMap = try CacheMap(count: metadata.brickMetadata.count)
      logger?.dev("Creating new cache map...")
    }

    // Load or create backing file.
    let incompleteFilename = filename + ".incomplete"
    let fileURL = URL(fileURLWithPath: incompleteFilename)
    if fileManager.fileExists(atPath: fileURL.path) {
      let existingFile = try MemoryMappedFile(filename: incompleteFilename, readOnly: false)
      if existingFile.fileSize >= cachedPayloadFileSize {
        self.dataFile = existingFile
      } else {
        try existingFile.close()
        try fileManager.removeItem(at: fileURL)
        self.cacheMap.clear()
        self.dataFile = try MemoryMappedFile(
          filename: incompleteFilename,
          size: cachedPayloadFileSize
        )
        let pointer = self.dataFile.mappedMemory.assumingMemoryBound(to: UInt64.self)
        pointer[0] = UInt64(cachedPayloadFileSize).littleEndian
        logger?.warning("Discarding an incomplete cache file that is smaller than its metadata.")
      }
    } else {
      self.cacheMap.clear()
      self.dataFile = try MemoryMappedFile(
        filename: incompleteFilename,
        size: cachedPayloadFileSize
      )

      // Store the file size at the beginning of the file.
      let pointer = self.dataFile.mappedMemory.assumingMemoryBound(to: UInt64.self)
      pointer[0] = UInt64(cachedPayloadFileSize).littleEndian
    }

    // Decompression setup.
    self.fullBrickSize = try Self.checkedProduct(
      metadata.brickSize,
      metadata.brickSize,
      metadata.brickSize,
      metadata.componentCount,
      metadata.bytesPerComponent
    )
    self.backgroundBufferSize = try Self.checkedProduct(
      fullBrickSize,
      self.maxBricksPerGetRequest
    )
    if metadata.compression {
      let scratchBufferSize = compression_decode_scratch_buffer_size(COMPRESSION_LZ4)
      self.compressionScratchBuffer = UnsafeMutableRawPointer.allocate(
        byteCount: scratchBufferSize,
        alignment: MemoryLayout<UInt8>.alignment
      )
    }
    self.tempDataBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: fullBrickSize)
    self.tempDataBufferBackground = UnsafeMutablePointer<UInt8>
      .allocate(capacity: backgroundBufferSize)

    // Initialize the request queue (initially empty).
    self.requestQueue = []

    // Start background worker.
    workerQueue.setSpecific(key: workerQueueKey, value: ())
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
    guard lifecycle.requestStop() else { return }
    workerTask?.cancel()
    requestSemaphore.signal() // Wake worker if waiting.
    if DispatchQueue.getSpecific(key: workerQueueKey) == nil {
      workerQueue.sync(flags: .barrier) {}
    }
  }

  deinit {
    stopWorker()
    if lifecycle.isCachingComplete {
      finalizeLocalCopyIfNeeded()
    } else {
      let cacheMapURL = URL(fileURLWithPath: targetFilename).appendingPathExtension("cachemap")
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
    if cacheMap.isSet(index: minResBrick) {
      try getLocalBrick(index: minResBrick, outputBuffer: outputBuffer)
      return
    }

    enqueue(index: minResBrick)
    let waitResult = lifecycle.waitUntilAvailable(
      deadline: Date().addingTimeInterval(firstBrickWaitTimeout)
    ) { [cacheMap] in
      cacheMap.isSet(index: minResBrick)
    }

    switch waitResult {
      case .available:
        try getLocalBrick(index: minResBrick, outputBuffer: outputBuffer)
      case .stopped(let lastError):
        throw lastError ?? BORGVRDataError.networkError(
          message: "Dataset caching stopped before the first brick became available."
        )
      case .timedOut(let lastError):
        throw lastError ?? BORGVRRemoteDataManagerError.timeout(
          seconds: firstBrickWaitTimeout
        )
    }
  }

  /**
   Retrieves a brick at the specified index, with control over asynchronous fetching.

   If the brick is already cached, it is retrieved from local storage.
   
   - Parameters:
   - index: The index of the brick.
   - outputBuffer: A pointer to a memory area with capacity at least the brick size.
   - Throws: A BORGVRDataError if the brick is not yet available or retrieval fails.
   */
  func getBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    if cacheMap.isSet(index: index) {
      try getLocalBrick(index: index, outputBuffer: outputBuffer)
      return
    }

    enqueue(index: index)
    throw BORGVRDataError.brickNotYetAvailable(index: index)
  }

  func getRawBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws -> Int? {
    let metadata = getMetadata()
    guard metadata.brickMetadata.indices.contains(index) else {
      throw BORGVRDataError.networkError(message: "Brick request contains an invalid index.")
    }
    guard cacheMap.isSet(index: index) else {
      enqueue(index: index)
      throw BORGVRDataError.brickNotYetAvailable(index: index)
    }
    let brickMeta = metadata.brickMetadata[index]
    try metadata.validateStoredBrickByteCount(brickMeta.size, fullBrickByteCount: fullBrickSize)
    return dataFileLock.withLock {
      memcpy(outputBuffer, dataFile.mappedMemory.advanced(by: brickMeta.offset), brickMeta.size)
      return brickMeta.size
    }
  }

  private func enqueue(index: Int) {
    let inserted = requestQueueLock.sync {
      guard !requestQueue.contains(index) else { return false }
      requestQueue.append(index)
      return true
    }
    if inserted {
      requestSemaphore.signal()
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
    var lastIndex = cacheMap.count - 1
    while !lifecycle.isTerminated {
      if cacheMap.isComplete() {
        lifecycle.markCachingComplete()
        logger?.dev("All bricks are locally cached")
        if finalizeLocalCopyIfNeeded() {
          break
        }
        _ = requestSemaphore.wait(timeout: .now() + 5)
        continue
      }

      var indicesToProcess =  Set<Int>()

      // First: priority requests from getBrick unless we have already
      //        cached that brick
      requestQueueLock.sync {
        requestQueue.removeAll { cacheMap.isSet(index: $0) }
        let take = min(maxBricksPerGetRequest, requestQueue.count)
        indicesToProcess = Set(requestQueue.prefix(take))
        requestQueue.removeFirst(take)
      }

      // Second: background prefetch from cacheMap to compete the dataset
      //         load lower resolutions first
      if indicesToProcess.count < maxBricksPerGetRequest && !cacheMap.isComplete() {
        while lastIndex >= 0 && indicesToProcess.count < maxBricksPerGetRequest {
          if !cacheMap.isSet(index: lastIndex) {
            indicesToProcess.insert(lastIndex)
          }
          lastIndex-=1
        }
      }


      // Wait if no work is available.
      if indicesToProcess.isEmpty {
        requestSemaphore.wait()
        continue
      }

      do {
        let indexArray = Array(indicesToProcess.sorted())

        let brickMeta = try remoteDataSource.getRawBricks(
          indices: indexArray,
          outputBuffer: tempDataBufferBackground,
          outputBufferSize: backgroundBufferSize
        )

        var offset = 0
        for (meta,index) in zip(brickMeta,indexArray) {
          let brickPtr = tempDataBufferBackground.advanced(by: offset)
          try setLocalBrick(index: index,
                            brickMeta: meta,
                            buffer: brickPtr)
          offset += meta.size
        }
        logger?.dev("Cached \(cacheMap.fillRatio*100) % of the dataset.")


        if cacheMap.isComplete() {
          lifecycle.markCachingComplete()
          logger?.dev("All bricks are locally cached")
          if finalizeLocalCopyIfNeeded() {
            break
          }
          _ = requestSemaphore.wait(timeout: .now() + 5)
        }
      } catch {
        // Keep failed prefetch ranges eligible. Otherwise a temporary outage
        // advances lastIndex past bricks that will never be considered again.
        if let highestFailedIndex = indicesToProcess.max() {
          lastIndex = max(lastIndex, highestFailedIndex)
        }
        lifecycle.recordFetchFailure(error)
        if Date().timeIntervalSince(lastFetchFailureLog) >= 5 {
          logger?.warning(
            "Remote dataset caching is waiting for a source: \(error.localizedDescription)"
          )
          lastFetchFailureLog = Date()
        }
        Thread.sleep(forTimeInterval: 0.25)
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
  private func setLocalBrick(index: Int, brickMeta: BrickMetadata,
                             buffer: UnsafeMutablePointer<UInt8>) throws {
    dataFileLock.lock()
    defer { dataFileLock.unlock() }

    memcpy(
      dataFile.mappedMemory.advanced(by: brickMeta.offset),
      buffer,
      brickMeta.size
    )
    guard cacheMap.set(index: index) else {
      throw BORGVRDataError.networkError(message: "Received an invalid cache brick index.")
    }
    lifecycle.recordBrickAvailable()
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
    try getMetadata().validateStoredBrickByteCount(brickMeta.size, fullBrickByteCount: fullBrickSize)
    dataFileLock.lock()
    defer { dataFileLock.unlock() }

    memcpy(tempDataBuffer, dataFile.mappedMemory.advanced(by: brickMeta.offset), brickMeta.size)
    try decompressRawBrick(inputBuffer: tempDataBuffer, outputBuffer: outputBuffer, brickMeta: brickMeta)
  }

  @discardableResult
  private func finalizeLocalCopyIfNeeded() -> Bool {
    guard lifecycle.beginFinalization() else {
      return lifecycle.isLocalCopyFinalized
    }

    dataFileLock.lock()
    let cacheMapURL = URL(fileURLWithPath: targetFilename).appendingPathExtension("cachemap")
    let incompleteFilename = targetFilename + ".incomplete"
    let fileManager = FileManager.default
    let incompleteURL = URL(fileURLWithPath: incompleteFilename)
    let completeURL = URL(fileURLWithPath: targetFilename)
    let metadata = remoteDataSource.getMetadata()
    var completion: BORGVRLocalDatasetCacheCompletion?
    var finalizationError: Error?
    var movedToComplete = false

    do {
      try dataFile.close()
      let fileHandle = try FileHandle(forWritingTo: incompleteURL)
      try fileHandle.truncate(atOffset: UInt64(cachedPayloadFileSize))
      try fileHandle.close()
      try metadata.save(filename: incompleteFilename)
      if fileManager.fileExists(atPath: completeURL.path) {
        try fileManager.removeItem(at: completeURL)
      }
      try fileManager.moveItem(at: incompleteURL, to: completeURL)
      movedToComplete = true
      try? fileManager.removeItem(at: cacheMapURL)
      dataFile = try MemoryMappedFile(filename: targetFilename, readOnly: true)
      completion = BORGVRLocalDatasetCacheCompletion(
        datasetID: metadata.uniqueID,
        fileURL: completeURL
      )
    } catch {
      finalizationError = error
      do {
        if fileManager.fileExists(atPath: incompleteURL.path) {
          dataFile = try MemoryMappedFile(filename: incompleteFilename, readOnly: false)
          try? cacheMap.save(to: cacheMapURL)
        } else if movedToComplete, fileManager.fileExists(atPath: completeURL.path) {
          dataFile = try MemoryMappedFile(filename: targetFilename, readOnly: true)
          try? fileManager.removeItem(at: cacheMapURL)
          completion = BORGVRLocalDatasetCacheCompletion(
            datasetID: metadata.uniqueID,
            fileURL: completeURL
          )
        } else {
          throw BORGVRDataError.networkError(
            message: "Neither the incomplete nor finalized cache file exists."
          )
        }
      } catch let recoveryError {
        logger?.error(
          "Error reopening cached data after finalize failure: \(recoveryError)"
        )
      }
    }
    dataFileLock.unlock()

    let succeeded = completion != nil
    lifecycle.finishFinalization(success: succeeded)
    if let completion {
      logger?.dev("Dataset caching complete, finalized local copy: \(targetFilename)")
      NotificationCenter.default.post(
        name: BORGVRLocalDatasetCacheCompletion.notification,
        object: completion
      )
    } else if let finalizationError {
      logger?.error("Error while completing dataset caching: \(finalizationError)")
    }
    return succeeded
  }

  private static func checkedProduct(_ factors: Int...) throws -> Int {
    var result = 1
    for factor in factors {
      guard factor > 0 else {
        throw BORGVRDataError.networkError(message: "Invalid cache buffer size.")
      }
      let product = result.multipliedReportingOverflow(by: factor)
      guard !product.overflow else {
        throw BORGVRDataError.networkError(message: "Cache buffer size is too large.")
      }
      result = product.partialValue
    }
    return result
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
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of Duisburg-Essen

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
