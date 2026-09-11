import Network
import Foundation

/**
 A set of errors that may occur when using the remote data manager.
 */
enum BORGVRRemoteDataManagerError: Error, LocalizedError {
  /// Connection failed with a reason.
  case connectionFailed(reason: String)
  /// Connection timed out after a specified duration.
  case timeout(seconds: TimeInterval)
  /// Sending a command failed with an error.
  case sendFailed(Error)
  /// Receiving data failed with a reason.
  case receiveFailed(reason: String)
  /// The response is invalid.
  case invalidResponse(reason: String)
  /// Some unknown error occurred.
  case unknown(Error)

  /// A localized description of the error.
  var errorDescription: String? {
    switch self {
      case .connectionFailed(let reason):
        return "Connection failed: \(reason)"
      case .timeout(let seconds):
        return "Connection timed out after \(Int(seconds)) seconds."
      case .sendFailed(let error):
        return "Failed to send command: \(error.localizedDescription)"
      case .receiveFailed(let reason):
        return "Failed to receive response: \(reason)"
      case .invalidResponse(let reason):
        return "Received invalid or unexpected response from server: \(reason)"
      case .unknown(let error):
        return "An unknown error occurred: \(error.localizedDescription)"
    }
  }
}

/**
 A manager for remote BorgVR dataset operations via a TCP connection.

 This class handles the network connection using NWConnection, and allows the user
 to request a dataset list, open a dataset on a new connection, and send/receive
 commands and binary responses.
 */
class BORGVRRemoteDataManager {
  struct RemoteTransferFunctionInfo: Equatable {
    let id: String
    let byteCount: Int
    let description: String
  }

  /// The underlying NWConnection for this manager.
  private let connection: NWConnection
  /// The local list of datasets.
  private var datasets: [(id: String, description: String)] = []
  /// The remote list of transfer functions.
  private var transferFunctions: [RemoteTransferFunctionInfo] = []
  /// An optional logger for logging messages.
  private let logger: LoggerBase?
  /// An optional notifier
  private let notifier: NotificationBase?
  /// The host of the remote server.
  private let host: String
  /// The port number used to connect to the remote server.
  private let port: UInt16
  private let authSecret: String

  private static let protocolVersionName : String = BorgVRServerAuthentication.protocolVersionName
  private(set) var maxBricksPerGetRequest : Int = 1
  /**
   Initializes a new instance of the remote data manager.

   - Parameters:
   - host: The host name or IP address of the remote server.
   - port: The port number to connect on.
   - logger: An optional logger for debug/info logging.
   */
  init(
    host: String,
    port: UInt16,
    authSecret: String? = nil,
    logger: LoggerBase?,
    notifier: NotificationBase?
  ) {
    self.logger = logger
    self.notifier = notifier
    self.host = host
    self.port = port
    self.authSecret = BorgVRServerAuthentication.normalizedSecret(authSecret)
    self.connection = NWConnection(host: NWEndpoint.Host(host),
                                   port: NWEndpoint.Port(rawValue: port)!,
                                   using: .tcp)
    logger?.dev("BORGVRRemoteDataManager initialized")
  }

  deinit {
    connection.cancel()
    logger?.dev("BORGVRRemoteDataManager deinitialized")
  }

  /**
   Establishes a connection to the remote server with a timeout.

   - Parameter timeout: The timeout period in seconds.
   - Throws: A BORGVRRemoteDataManagerError if the connection cannot be
   established within the timeout period.
   */
  func connect(timeout: Double) throws {
    try BORGVRRemoteDataManager.connect(connection: connection,
                                        timeout: timeout, logger: logger)
    try BorgVRServerAuthentication.authenticate(
      connection: connection,
      secret: authSecret,
      timeout: timeout,
      logger: logger
    )
    try getInfo()
  }

  /**
   A helper method that performs the connection process on a given NWConnection.

   - Parameters:
   - connection: The NWConnection to establish.
   - timeout: The timeout period in seconds.
   - logger: An optional logger to log connection status.
   - Throws: A BORGVRRemoteDataManagerError in case of timeout or failure.
   */
  static func connect(connection: NWConnection, timeout: Double,
                      logger: LoggerBase? = nil) throws {
    let semaphore = DispatchSemaphore(value: 0)
    var success = false

    connection.stateUpdateHandler = { state in
      switch state {
        case .ready:
          logger?.dev("Connected to server.")
          success = true
          semaphore.signal()
        case .failed(let error):
          logger?.error("Connection failed: \(error)")
          semaphore.signal()
        case .waiting(let error):
          logger?.warning("Connection waiting: \(error)")
          semaphore.signal()
        case .preparing:
          logger?.dev("Preparing connection...")
        default:
          break
      }
    }
    connection.start(queue: .global())

    let timeoutResult = semaphore.wait(timeout: .now() + timeout)
    if timeoutResult == .timedOut {
      connection.cancel()
      throw BORGVRRemoteDataManagerError.timeout(seconds: timeout)
    }

    if !success {
      throw BORGVRRemoteDataManagerError.connectionFailed(
        reason: "Failed to connect to server."
      )
    }
  }
  
  private func getInfo() throws {
    try sendCommand("INFO")
    let response = try receiveTextResponse()

    let data = KeyValuePairHandler(text:response)

    guard let versionString = data["VERSION"] else {
      throw BORGVRRemoteDataManagerError.invalidResponse(reason:"Version not found in info response.")
    }
    
    guard BORGVRRemoteDataManager.serverProtocolVersion(versionString) >=
            BORGVRRemoteDataManager.serverProtocolVersion(BORGVRRemoteDataManager.protocolVersionName) else {
      throw BORGVRRemoteDataManagerError.invalidResponse(reason: "Unsupported server protocol version. Server: \(versionString) (Local: \(BORGVRRemoteDataManager.protocolVersionName)).")
    }

    if let maxBricksPerGetRequest = data.int(for: "MAX_BRICKS_PER_GET_REQUEST") {
      self.maxBricksPerGetRequest = maxBricksPerGetRequest
    } else {
      throw BORGVRRemoteDataManagerError.invalidResponse(reason: "Could not parse brick request limit from server response.")
    }
  }
    /**
   Requests the dataset list from the remote server.

   - Returns: An array of tuples containing dataset id and description.
   - Throws: An error if sending or receiving the command fails.
   */
  func requestDatasetList() throws -> [(id: String, description: String)] {
    try sendCommand("LIST")
    let response = try receiveTextResponse()

    let lines = response.split(separator: "\n")
    self.datasets = try lines.compactMap { line in
      let parts = line.split(separator: " ", maxSplits: 1)
      guard parts.count > 1 else {
        throw BORGVRRemoteDataManagerError.invalidResponse(reason: "List response too short.")
      }

      // make sure the id is properly formated
      let idString = String(parts[0])
      if UUID(uuidString: idString) != nil {
        return (id: idString, description: String(parts[1]))
      } else {
        throw BORGVRRemoteDataManagerError.invalidResponse(reason: "Invalid ID in List response.")
      }

    }
    return self.datasets
  }

  func requestTransferFunctionList() throws -> [RemoteTransferFunctionInfo] {
    try sendCommand("LISTTF")
    let response = try receiveTextResponse()
    let lines = response.split(separator: "\n", omittingEmptySubsequences: true)

    self.transferFunctions = try lines.compactMap { line in
      let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
      guard parts.count >= 2 else {
        throw BORGVRRemoteDataManagerError.invalidResponse(reason: "Transfer function list response too short.")
      }

      let id = String(parts[0])
      guard Self.isTransferFunctionIdentifier(id) else {
        throw BORGVRRemoteDataManagerError.invalidResponse(reason: "Invalid transfer function ID in LISTTF response.")
      }

      guard let byteCount = Int(parts[1]), byteCount > 0 else {
        throw BORGVRRemoteDataManagerError.invalidResponse(reason: "Invalid transfer function byte count in LISTTF response.")
      }

      let description = parts.count > 2 ? String(parts[2]) : ""
      return RemoteTransferFunctionInfo(id: id, byteCount: byteCount, description: description)
    }
    return self.transferFunctions
  }

  func requestTransferFunction(id: String) throws -> Data {
    guard Self.isTransferFunctionIdentifier(id) else {
      throw BORGVRRemoteDataManagerError.invalidResponse(reason: "Invalid transfer function ID.")
    }
    try sendCommand("GETTF \(id)")
    return try receiveBinaryData()
  }

  /**
   Opens a dataset on a new connection.

   A new NWConnection is created and used to open the dataset.

   - Parameters:
   - datasetID: The dataset identifier.
   - timeout: The timeout for establishing the connection.
   - localCacheFilename: An optional local cache file name.
   - Returns: A BORGVRRemoteData instance representing the open dataset.
   - Throws: An error if the connection fails.
   */
  func openDataset(datasetID: String, timeout: Double,
                   localCacheFilename: String? = nil) throws -> BORGVRRemoteData  {
    let datasetConnection = NWConnection(
      host: NWEndpoint.Host(host),
      port: NWEndpoint.Port(rawValue: port)!,
      using: .tcp
    )

    try BORGVRRemoteDataManager.connect(connection: datasetConnection,
                                        timeout: timeout, logger: logger)
    try BorgVRServerAuthentication.authenticate(
      connection: datasetConnection,
      secret: authSecret,
      timeout: timeout,
      logger: logger
    )
    return try BORGVRRemoteData(connection: datasetConnection,
                                datasetID: datasetID,
                                maxBricksPerGetRequest: maxBricksPerGetRequest,
                                targetFilename: localCacheFilename,
                                authSecret: authSecret,
                                logger:logger,
                                notifier: notifier)
  }

  /**
   Sends a command string over the connection.

   - Parameter command: The command to send.
   - Throws: A BORGVRRemoteDataManagerError if sending fails or times out.
   */
  private func sendCommand(_ command: String) throws {
    try BorgVRServerAuthentication.sendCommand(command, connection: connection)
  }

  /**
   Receives a textual response from the server.

   This method attempts to read data until a double newline ("\n\n") is encountered.

   - Parameter timeout: The timeout in seconds for the response.
   - Returns: A string containing the response.
   - Throws: A BORGVRRemoteDataManagerError if reception times out or fails.
   */
  private func receiveTextResponse(timeout: TimeInterval = 5.0) throws -> String {
    try BorgVRServerAuthentication.receiveTextResponse(connection: connection, timeout: timeout)
  }

  private func receiveBinaryData(timeout: TimeInterval = 15.0) throws -> Data {
    var sizeData = Data()
    while sizeData.count < MemoryLayout<UInt32>.size {
      let chunk = try receiveData(
        minimumLength: 1,
        maximumLength: MemoryLayout<UInt32>.size - sizeData.count,
        timeout: timeout
      )
      sizeData.append(chunk)
    }

    let payloadSize = Int(
      UInt32(sizeData[0]) |
      (UInt32(sizeData[1]) << 8) |
      (UInt32(sizeData[2]) << 16) |
      (UInt32(sizeData[3]) << 24)
    )
    guard payloadSize >= 0 else {
      throw BORGVRRemoteDataManagerError.invalidResponse(reason: "Invalid binary response size.")
    }

    var payload = Data()
    while payload.count < payloadSize {
      let remaining = payloadSize - payload.count
      let chunk = try receiveData(
        minimumLength: 1,
        maximumLength: min(remaining, 64 * 1024),
        timeout: timeout
      )
      payload.append(chunk)
    }
    return payload
  }

  private func receiveData(
    minimumLength: Int,
    maximumLength: Int,
    timeout: TimeInterval
  ) throws -> Data {
    let semaphore = DispatchSemaphore(value: 0)
    var chunk: Data?
    var receiveError: Error?

    connection.receive(
      minimumIncompleteLength: minimumLength,
      maximumLength: maximumLength
    ) { data, _, _, error in
      chunk = data
      receiveError = error
      semaphore.signal()
    }

    let result = semaphore.wait(timeout: .now() + timeout)
    if result == .timedOut {
      throw BORGVRRemoteDataManagerError.timeout(seconds: timeout)
    }
    if let receiveError {
      throw BORGVRRemoteDataManagerError.receiveFailed(reason: receiveError.localizedDescription)
    }
    guard let chunk, !chunk.isEmpty else {
      throw BORGVRRemoteDataManagerError.receiveFailed(reason: "Missing binary response data.")
    }
    return chunk
  }

  private static func isTransferFunctionIdentifier(_ id: String) -> Bool {
    id.count == 32 && id.allSatisfy { character in
      character.isHexDigit
    }
  }

  private static func serverProtocolVersion(_ version: String) -> Int {
    Int(version) ?? 0
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
 BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
 OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
 IN THE SOFTWARE.
 */
