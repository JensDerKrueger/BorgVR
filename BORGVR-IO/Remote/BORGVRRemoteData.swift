import Network
import Foundation

enum RemoteDatasetOpenError: LocalizedError {
  case documentsDirectoryUnavailable, downloadStalled, downloadCancelled, noReachableOrigin
  var errorDescription: String? {
    switch self {
      case .documentsDirectoryUnavailable: String(localized: "The documents directory is not available.")
      case .downloadStalled: String(localized: "The remote download is no longer making progress.")
      case .downloadCancelled: String(localized: "The remote download was paused.")
      case .noReachableOrigin: String(localized: "The dataset is not available from any known source.")
    }
  }
}

enum RemoteDatasetDownloader {
  static func download(datasetID: String, origin: DatasetOrigin, to target: URL, timeout: TimeInterval,
                       cancellation: RemoteRequestCancellation, originProvider: @escaping DatasetOriginProvider,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
    try await withTaskCancellationHandler {
      try await Task.detached(priority: .userInitiated) {
        try cancellation.check()
        let manager = BORGVRRemoteDataManager(host: origin.address, port: UInt16(clamping: origin.port),
          authSecret: origin.password, logger: nil)
        let connecting = cancellation.register { [weak manager] in manager?.cancel() }
        defer { cancellation.remove(connecting) }
        do {
          try manager.connect(timeout: timeout)
          try cancellation.check()
          let dataset = try manager.openDataset(datasetID: datasetID, timeout: timeout,
            localCacheFilename: target.path, originProvider: originProvider)
          let downloading = cancellation.register { [weak dataset] in dataset?.stop() }
          defer { cancellation.remove(downloading); dataset.stop() }
          guard dataset.getMetadata().uniqueID.caseInsensitiveCompare(datasetID) == .orderedSame else {
            throw BORGVRRemoteDataManagerError.invalidResponse(reason: "Downloaded dataset ID does not match the request.")
          }
          let clock = ContinuousClock()
          var lastProgress = -1.0, lastChange = clock.now
          let stallTimeout = max(30, timeout * 10)
          let incomplete = target.appendingPathExtension("incomplete")
          while true {
            try cancellation.check()
            let value = dataset.localRatio
            if value > lastProgress + 0.001 {
              lastProgress = value; lastChange = clock.now; progress(value)
            }
            if value >= 1, FileManager.default.fileExists(atPath: target.path),
               !FileManager.default.fileExists(atPath: incomplete.path) { return target }
            if lastChange.duration(to: clock.now) > .seconds(stallTimeout) { throw RemoteDatasetOpenError.downloadStalled }
            try await Task.sleep(for: .milliseconds(200))
          }
        } catch {
          if cancellation.isCancelled { throw CancellationError() }
          throw error
        }
      }.value
    } onCancel: { cancellation.cancel() }
  }
}

/**
 A remote volume data handler that wraps a brick data source.

 BORGVRRemoteData provides a unified interface to access volume bricks,
 whether the source is local, remote, or cached remotely. It conforms to
 BORGVRDatasetProtocol.
 */
class BORGVRRemoteData: BORGVRDatasetProtocol {

  // MARK: - Properties

  /// The underlying data source for brick data.
  private let brickDataSource: DataSource
  /// An optional logger for debug and error messages.
  private let logger: LoggerBase?

  /**
   Represents the type of the underlying data source.

   - local: Data is read from a local file.
   - cachingRemote: Data is fetched remotely and cached locally.
   - remote: Data is accessed directly from a remote source.
   */
  enum SourceType {
    case local
    case cachingRemote
    case remote
  }

  /// The source type, determined dynamically based on brickDataSource.
  var sourceType: SourceType {
    switch brickDataSource {
      case is LocalDataSource:
        return .local
      case is CachingRemoteDataSource:
        return .cachingRemote
      case is RemoteDataSource:
        return .remote
      default:
        fatalError("Unknown data source type")
    }
  }

  var localRatio : Double {
    switch brickDataSource {
      case is LocalDataSource:
        return 1.0
      case is CachingRemoteDataSource:
        let cachingRemoteDataSource = brickDataSource as! CachingRemoteDataSource
        if cachingRemoteDataSource.cachingComplete {
          return 1.0
        } else {
          return cachingRemoteDataSource.cacheMap.fillRatio
        }
      case is RemoteDataSource:
        return 0.0
      default:
        fatalError("Unknown data source type")
    }
  }

  var localFile : String? {
    switch brickDataSource {
    case is LocalDataSource:
      let localDataSource = brickDataSource as! LocalDataSource
        return localDataSource.filename
    case is CachingRemoteDataSource:
      let cachingRemoteDataSource = brickDataSource as! CachingRemoteDataSource
      return cachingRemoteDataSource.targetFilename
    case is RemoteDataSource:
      return nil
    default:
      fatalError("Unknown data source type")
    }
  }

  /**
   Initializes a new BORGVRRemoteData instance.

   Depending on the provided targetFilename, the initializer attempts to open a local file.
   If the file does not exist or cannot be opened, it falls back to using a caching remote data source.
   If no targetFilename is provided, a remote data source is used.

   - Parameters:
   - connection: The NWConnection to the remote server.
   - datasetID: The identifier of the dataset.
   - targetFilename: An optional file path for a local data source.
   - Throws: An error if initializing the underlying data source fails.
   */
  init(connection: NWConnection, datasetID: String,
       maxBricksPerGetRequest: Int,
       targetFilename: String?,
       primaryOrigin: DatasetOrigin,
       connectionTimeout: TimeInterval,
       originProvider: @escaping DatasetOriginProvider,
       authSecret: String? = nil,
       logger:LoggerBase?) throws {

    self.logger = logger

    if let targetFilename = targetFilename {
      let fullURL = URL(fileURLWithPath: targetFilename)
      let fileManager = FileManager.default
      if fileManager.fileExists(atPath: fullURL.path) {
        do {
          logger?.dev("Remote dataset is already locally cached")
          self.brickDataSource = try LocalDataSource(filename: targetFilename,
                                                     logger:logger)
        } catch {
          logger?.warning("Loading local dataset failed, using remote instead")
          self.brickDataSource = try CachingRemoteDataSource(
            connection: connection,
            datasetID: datasetID,
            maxBricksPerGetRequest: maxBricksPerGetRequest,
            filename: targetFilename,
            primaryOrigin: primaryOrigin,
            connectionTimeout: connectionTimeout,
            originProvider: originProvider,
            authSecret: authSecret,
            logger:logger
          )
        }
      } else {
        logger?.dev("Loading remote and caching locally")
        self.brickDataSource = try CachingRemoteDataSource(
          connection: connection,
          datasetID: datasetID,
          maxBricksPerGetRequest: maxBricksPerGetRequest,
          filename: targetFilename,
          primaryOrigin: primaryOrigin,
          connectionTimeout: connectionTimeout,
          originProvider: originProvider,
          authSecret: authSecret,
          logger:logger)
      }
    } else {
      logger?.dev("Loading remote dataset directly")
      self.brickDataSource = try RemoteDataSource(
        connection: connection,
        datasetID: datasetID,
        primaryOrigin: primaryOrigin,
        maxBricksPerGetRequest: maxBricksPerGetRequest,
        connectionTimeout: connectionTimeout,
        originProvider: originProvider,
        authSecret: authSecret,
        logger:logger)
    }
    logger?.dev("BORGVRRemoteData initialized")
  }

  deinit {
    stop()
    logger?.dev("BORGVRRemoteData deinitialized")
  }

  func stop() {
    (brickDataSource as? CachingRemoteDataSource)?.stopWorker()
    (brickDataSource as? RemoteDataSource)?.stop()
  }

  /**
   Retrieves the brick at the specified index and writes its data into the provided output buffer.

   - Parameters:
   - index: The index of the brick to retrieve.
   - outputBuffer: A pointer to a memory area with sufficient capacity.
   - Throws: An error if retrieving the brick fails.
   */
  func getBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    try self.brickDataSource.getBrick(index: index, outputBuffer: outputBuffer)
  }

  func getRawBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws -> Int? {
    try brickDataSource.getRawBrick(index: index, outputBuffer: outputBuffer)
  }

  /**
   Retrieves the first brick and writes its data into the provided output buffer.
   In contrast to getBrick, this call is always synchronous.

   - Parameter outputBuffer: A pointer to a memory area with sufficient capacity.
   - Throws: An error if retrieving the brick fails.
   */
  public func getFirstBrick(outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    try self.brickDataSource.getFirstBrick(outputBuffer: outputBuffer)
  }

  /**
   Returns the metadata for the current dataset.

   - Returns: A BORGVRMetaData object describing the dataset.
   */
  func getMetadata() -> BORGVRMetaData {
    self.brickDataSource.getMetadata()
  }

  /**
   Allocates a new buffer for storing brick data.

   The buffer's capacity is determined by the full brick size computed from the dataset metadata.

   - Returns: An allocated UnsafeMutablePointer<UInt8> with sufficient capacity.
   */
  func allocateBrickBuffer() -> UnsafeMutablePointer<UInt8> {
    let metadata = self.getMetadata()
    let fullBrickSize = metadata.brickSize * metadata.brickSize * metadata.brickSize *
    metadata.componentCount * metadata.bytesPerComponent
    return UnsafeMutablePointer<UInt8>.allocate(capacity: fullBrickSize)
  }

  func newRequest() {
    if let cachingSource = brickDataSource as? CachingRemoteDataSource {
      cachingSource.newRequest()
    }
  }

}

/*
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of
 Duisburg-Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of
 this software and associated documentation files (the "Software"), to deal in the
 Software without restriction, including without limitation the rights to use,
 copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the
 Software, and to permit persons to whom the Software is furnished to do so, subject
 to the following conditions:

 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
 CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR
 THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
