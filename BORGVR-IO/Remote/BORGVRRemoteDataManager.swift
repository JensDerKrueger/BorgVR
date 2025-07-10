import Network
import Foundation

/**
 A set of errors that may occur when using the remote data manager.
 */
enum BORGVRRemoteDataManagerError: Error {
  /// Connection failed with a reason.
  case connectionFailed(reason: String)
  /// Connection timed out after a specified duration.
  case timeout(seconds: TimeInterval)
  /// Sending a command failed with an error.
  case sendFailed(Error)
  /// Receiving data failed with a reason.
  case receiveFailed(reason: String)
  /// The response is invalid.
  case invalidResponse
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
      case .invalidResponse:
        return "Received invalid or unexpected response from server."
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
  /// The underlying NWConnection for this manager.
  private let connection: NWConnection
  /// The local list of datasets.
  private var datasets: [(id: Int, description: String)] = []
  /// An optional logger for logging messages.
  private let logger: LoggerBase?
  /// The host of the remote server.
  private let host: String
  /// The port number used to connect to the remote server.
  private let port: UInt16

  /**
   Initializes a new instance of the remote data manager.

   - Parameters:
   - host: The host name or IP address of the remote server.
   - port: The port number to connect on.
   - logger: An optional logger for debug/info logging.
   */
  init(host: String, port: UInt16, logger: LoggerBase?) {
    self.logger = logger
    self.host = host
    self.port = port
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
  }

  /**
   A helper method that performs the connection process on a given NWConnection.

   - Parameters:
   - connection: The NWConnection to establish.
   - timeout: The timeout period in seconds.
   - logger: An optional logger to log connection status.
   - Throws: A BORGVRRemoteDataManagerError in case of timeout or failure.
   */
  static private func connect(connection: NWConnection, timeout: Double,
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

  /**
   Requests the dataset list from the remote server.

   - Returns: An array of tuples containing dataset id and description.
   - Throws: An error if sending or receiving the command fails.
   */
  func requestDatasetList() throws -> [(id: Int, description: String)] {
    try sendCommand("LIST")
    let response = try receiveTextResponse()

    let lines = response.split(separator: "\n")
    self.datasets = lines.compactMap { line in
      let parts = line.split(separator: " ", maxSplits: 1)
      guard let id = Int(parts[0]), parts.count > 1 else { return nil }
      return (id: id, description: String(parts[1]))
    }
    return self.datasets
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
  func openDataset(datasetID: Int, timeout: Double,
                   localCacheFilename: String? = nil,
                   asyncGet : Bool = true) throws -> BORGVRRemoteData  {
    let datasetConnection = NWConnection(
      host: NWEndpoint.Host(host),
      port: NWEndpoint.Port(rawValue: port)!,
      using: .tcp
    )

    try BORGVRRemoteDataManager.connect(connection: datasetConnection,
                                        timeout: timeout, logger: logger)
    return try BORGVRRemoteData(connection: datasetConnection,
                                datasetID: datasetID,
                                asyncGet: true,
                                targetFilename: localCacheFilename,
                                logger:logger)
  }

  /**
   Sends a command string over the connection.

   - Parameter command: The command to send.
   - Throws: A BORGVRRemoteDataManagerError if sending fails or times out.
   */
  private func sendCommand(_ command: String) throws {
    let semaphore = DispatchSemaphore(value: 0)
    var sendError: Error?

    let terminatedCommand = command.hasSuffix("\n") ? command : command + "\n"
    guard let commandData = terminatedCommand.data(using: .utf8) else {
      throw BORGVRRemoteDataManagerError.sendFailed(
        NSError(domain: "Encoding", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode command"])
      )
    }

    connection.send(content: commandData,
                    completion: .contentProcessed({ error in
      sendError = error
      semaphore.signal()
    }))

    let result = semaphore.wait(timeout: .now() + 5)
    if result == .timedOut {
      throw BORGVRRemoteDataManagerError.timeout(seconds: 5)
    }
    if let error = sendError {
      throw BORGVRRemoteDataManagerError.sendFailed(error)
    }
  }

  /**
   Receives a textual response from the server.

   This method attempts to read data until a double newline ("\n\n") is encountered.

   - Parameter timeout: The timeout in seconds for the response.
   - Returns: A string containing the response.
   - Throws: A BORGVRRemoteDataManagerError if reception times out or fails.
   */
  private func receiveTextResponse(timeout: TimeInterval = 5.0) throws -> String {
    let deadline = Date().addingTimeInterval(timeout)
    var buffer = Data()

    while Date() < deadline {
      let semaphore = DispatchSemaphore(value: 0)
      var chunk: Data?
      var receiveError: Error?

      connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
        chunk = data
        receiveError = error
        semaphore.signal()
      }

      let result = semaphore.wait(timeout: .now() + timeout)
      if result == .timedOut {
        throw BORGVRRemoteDataManagerError.timeout(seconds: timeout)
      }

      if let error = receiveError {
        throw BORGVRRemoteDataManagerError.receiveFailed(
          reason: error.localizedDescription
        )
      }

      if let data = chunk {
        buffer.append(data)
        if let str = String(data: buffer, encoding: .utf8),
           let range = str.range(of: "\n\n") {
          let endIndex = str.index(before: range.upperBound)
          return String(str[..<endIndex])
        }
      }
    }

    throw BORGVRRemoteDataManagerError.timeout(seconds: timeout)
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
 BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
 OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
 IN THE SOFTWARE.
 */
