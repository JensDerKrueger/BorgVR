import Network
import Foundation

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
   - asyncGet: A flag indicating whether to fetch data asynchronously.
   - targetFilename: An optional file path for a local data source.
   - Throws: An error if initializing the underlying data source fails.
   */
  init(connection: NWConnection, datasetID: Int,
       asyncGet: Bool, targetFilename: String?,
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
            asyncGet: asyncGet,
            filename: targetFilename,
            logger:logger)
        }
      } else {
        logger?.dev("Loading remote and caching locally")
        self.brickDataSource = try CachingRemoteDataSource(
          connection: connection,
          datasetID: datasetID,
          asyncGet: asyncGet,
          filename: targetFilename,
          logger:logger)
      }
    } else {
      logger?.dev("Loading remote dataset directly")
      self.brickDataSource = try RemoteDataSource(
        connection: connection,
        datasetID: datasetID,
        logger:logger)
    }
    logger?.dev("BORGVRRemoteData initialized")
  }

  deinit {
    if let cachingSource = brickDataSource as? CachingRemoteDataSource {
      cachingSource.stopWorker()
    }
    logger?.dev("BORGVRRemoteData deinitialized")
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
 Copyright (c) 2025 Computer Graphics and Visualization Group, University of
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
