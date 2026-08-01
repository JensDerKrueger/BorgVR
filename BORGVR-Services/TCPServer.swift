import Network
import Foundation

class TCPServer {
  static let protocolVersionName: String = "1"

  let port: NWEndpoint.Port
  let queue = DispatchQueue(label: "TCPServerQueue")
  var listener: NWListener?
  var activeConnections: [NWConnection] = []
  var isRunning = false
  var logger: LoggerBase?

  // Maximum number of bricks allowed in a single GETBRICKS request
  let maxBricksPerGetRequest: Int

  /// Dataset list received from the GUI
  private var datasets: [DatasetInfo]

  // Dataset and its reusable brick buffer for a single connection
  final class ConnectionDataset {
    let dataset: BORGVRFileData
    let buffer: UnsafeMutablePointer<UInt8>

    init(dataset: BORGVRFileData) {
      self.dataset = dataset
      self.buffer = dataset.allocateBrickBuffer()
    }

    deinit {
      buffer.deallocate()
    }
  }

  private var connectionDatasets: [ObjectIdentifier: ConnectionDataset] = [:]
  private let stateLock = NSLock()

  init(
    port: UInt16,
    maxBricksPerGetRequest: Int,
    logger: LoggerBase? = nil,
    datasets: [DatasetInfo] = []
  ) {
    self.logger = logger
    self.datasets = datasets

    if maxBricksPerGetRequest > 0 {
      self.maxBricksPerGetRequest = maxBricksPerGetRequest
    } else {
      logger?.error(String(
        format: L(
          "tcpserver_error_invalid_maxBricks",
          value: "Invalid maxBricksPerGetRequest %@, using 1.",
          comment: "Invalid maxBricksPerGetRequest of %@, defaulting to 1."
        ),
        String(maxBricksPerGetRequest)
      ))
      self.maxBricksPerGetRequest = 1
    }

    if let p = NWEndpoint.Port(rawValue: port) {
      self.port = p
    } else {
      logger?.error(
        String(
        format: L(
          "tcpserver_error_invalid_port",
          value: "Invalid port %@, defaulting to 12345.",
          comment: "Invalid port %@, defaulting to 12345."
        ),
        String(port)
      ))
      if let p = NWEndpoint.Port(rawValue: 12345) {
        self.port = p
      } else {
        logger?.error(L("tcpserver_error_invalid_port_default",
                        value: "Unable to set the default port.",
                        comment: "Unable to set a default port."))
        self.port = 0
      }
    }
  }

  func start() {
    do {
      listener = try NWListener(using: .tcp, on: port)
    } catch {
      logger?.error(
        L("tcpserver_error_create_listener",
          value: "Could not create listener:",
          comment: "failed to create TCP listener") + " \(error)"
      )
      return
    }

    listener?.newConnectionHandler = { [weak self] connection in
      self?.handleNewConnection(connection)
    }

    listener?.start(queue: queue)
    isRunning = true
    logger?.info(
      String(
        format: L(
          "tcpserver_info_server_started",
          value: "Server with protocol version %@ started on port %@.",
          comment: "server started with protocol version and port"
        ),
        TCPServer.protocolVersionName,
        String(describing: port)
      )
    )
  }

  func stop() {
    listener?.cancel()
    let connections = activeConnectionsSnapshot()
    connections.forEach { connection in
      closeConnection(for: connection)
      connection.cancel()
    }
    removeAllActiveConnections()
    isRunning = false
    logger?.info(
      L(
        "tcpserver_info_server_stopped",
        value: "Server stopped.",
        comment: "server stopped"
      )
    )
  }

  private func handleNewConnection(_ connection: NWConnection) {
    appendActiveConnection(connection)

    connection.stateUpdateHandler = { [weak self, weak connection] state in
      guard let self, let connection else { return }
      switch state {
        case .cancelled, .waiting, .failed(_):
          self.closeConnection(for: connection)
          self.removeActiveConnection(connection)
        default:
          break
      }
    }
    connection.start(queue: queue)
    receiveLine(on: connection, buffer: "")
  }

  // MARK: - Parameter validation helpers

  private func expectParameterCount(
    _ parameters: ArraySlice<Substring>,
    equals expected: Int
  ) -> Bool {
    return parameters.count == expected
  }

  private func expectParameterCount(
    _ parameters: ArraySlice<Substring>,
    in range: ClosedRange<Int>
  ) -> Bool {
    return parameters.count >= range.lowerBound &&
    parameters.count <= range.upperBound
  }

  private func receiveLine(on connection: NWConnection, buffer: String) {
    connection.receive(
      minimumIncompleteLength: 1,
      maximumLength: 1024
    ) { [weak self] data, _, isComplete, error in
      guard let self = self else { return }

      if let error = error {
        self.logger?.warning(
          String(
            format: L(
              "tcpserver_warning_client_error_disconnect",
              value: "Client disconnected with error: %@.",
              comment: "client disconnected with error"
            ),
            error.localizedDescription
          )
        )
        self.closeConnection(for: connection)
        return
      }

      guard let data = data, !data.isEmpty else {
        if isComplete {
          self.logger?.info(
            L(
              "tcpserver_info_client_disconnected_normal",
              value: "Client disconnected normally.",
              comment: "client disconnected normally"
            )
          )
          self.closeConnection(for: connection)
        }
        return
      }

      var newBuffer = buffer + String(decoding: data, as: UTF8.self)

      while let newlineRange = newBuffer.range(of: "\n") {
        let request = newBuffer[..<newlineRange.lowerBound]
          .trimmingCharacters(in: .whitespacesAndNewlines)
        newBuffer = String(newBuffer[newlineRange.upperBound...])

        if !self.processCommand(request, connection: connection) {
          connection.cancel()
          return
        }
      }

      if isComplete {
        connection.cancel()
        self.logger?.info(
          L(
            "tcpserver_info_closing_connection_after_processing",
            value: "Closing connection after processing.",
            comment: "closing connection after processing"
          )
        )
        self.closeConnection(for: connection)
      } else {
        self.receiveLine(on: connection, buffer: newBuffer)
      }
    }
  }

  private func processCommand(
    _ command: String,
    connection: NWConnection
  ) -> Bool {
    let components = command.split(whereSeparator: \.isWhitespace)
    guard let cmd = components.first else {
      return false
    }

    let parameters = components.dropFirst()

    switch cmd.uppercased() {
      case "LIST":
        return sendList(parameters: parameters, connection: connection)

      case "OPEN":
        return openDataset(parameters: parameters, connection: connection)

      case "GETBRICKS":
        return getBricks(parameters: parameters, connection: connection)

      case "INFO":
        return sendInfo(parameters: parameters, connection: connection)

      default:
        return false
    }
  }

  private func openDataset(
    parameters: ArraySlice<Substring>,
    connection: NWConnection
  ) -> Bool {
    guard expectParameterCount(parameters, equals: 1) else { return false }

    guard
      let idString = parameters.first,
      let dataset = datasets.first(where: { $0.id == idString })
    else {
      logger?.warning(
        String(
          format: L(
            "tcpserver_warning_open_unknown_dataset",
            value: "OPEN: unknown dataset id %@.",
            comment: "unknown dataset id in OPEN"
          ),
          String(parameters.first ?? "")
        )
      )
      return false
    }

    let connectionID = ObjectIdentifier(connection)
    if connectionDataset(for: connection) != nil {
      logger?.info(
        L(
          "tcpserver_info_closing_previous_dataset",
          value: "Closing previous dataset for connection.",
          comment: "closing previous dataset for connection"
        )
      )
      closeConnection(for: connection)
    }

    if let data = try? BORGVRFileData(filename: dataset.filename) {
      setConnectionDataset(ConnectionDataset(dataset: data), for: connection)

      let filename = URL(fileURLWithPath: dataset.filename).lastPathComponent
      if case let .hostPort(host, _) = connection.endpoint {
        let clientAddress = host.debugDescription
        logger?.info(
          String(
            format: L(
              "tcpserver_info_opened_dataset_with_client",
              value: "Opened dataset %@ for %@ (connection %@).",
              comment: "opened dataset for client with id"
            ),
            filename,
            clientAddress,
            String(connectionID.hashValue)
          )
        )
      } else {
        logger?.info(
          String(
            format: L(
              "tcpserver_info_opened_dataset",
              value: "Opened dataset %@ (connection %@).",
              comment: "opened dataset with id"
            ),
            filename,
            String(connectionID.hashValue)
          )
        )
      }

      sendBinaryResponse(
        data: data.getMetadata().toData(),
        connection: connection
      )
      return true
    } else {
      logger?.error(
        String(
          format: L(
            "tcpserver_error_open_dataset_failed",
            value: "Failed to open dataset %@.",
            comment: "failed to open dataset"
          ),
          String(idString)
        )
      )
      return false
    }
  }

  private func convertToInts(
    _ indexStrings: ArraySlice<Substring>
  ) -> [Int]? {
    let ints = indexStrings.compactMap { Int($0) }
    return ints.count == indexStrings.count ? ints : nil
  }

  private func getBricks(
    parameters indexStrings: ArraySlice<Substring>,
    connection: NWConnection
  ) -> Bool {
    guard expectParameterCount(
      indexStrings,
      in: 1...Int(maxBricksPerGetRequest)
    ) else { return false }

    guard
      let indices = convertToInts(indexStrings),
      indices.count <= maxBricksPerGetRequest
    else {
      return false
    }

    guard let datasetEntry = connectionDataset(for: connection) else {
      return false
    }

    let metadata = datasetEntry.dataset.getMetadata()
    let bricks = metadata.brickMetadata
    let brickCount = bricks.count

    guard indices.allSatisfy({ $0 >= 0 && $0 < brickCount }) else {
      let rangeText = "0..\((brickCount - 1))"
      logger?.warning(
        String(
          format: L(
            "tcpserver_warning_getbricks_index_out_of_range",
            value: "GETBRICKS: index out of range (%@) in %@.",
            comment: "GETBRICKS index out of range"
          ),
          rangeText,
          "\(indices)"
        )
      )
      return false
    }

    var totalSize = 0
    for index in indices {
      let brickMeta = bricks[index]
      totalSize += brickMeta.size
    }

    do {
      var brickData = Data(capacity: totalSize)
      for index in indices {
        let brickMeta = bricks[index]
        try datasetEntry.dataset.getRawBrick(
          brickMeta: brickMeta,
          outputBuffer: datasetEntry.buffer
        )
        brickData.append(
          Data(bytes: datasetEntry.buffer, count: brickMeta.size)
        )
      }
      sendBinaryResponse(data: brickData, connection: connection)
      return true
    } catch {
      logger?.error(
        L(
          "tcpserver_error_getbricks_failed",
          value: "Failed to get bricks:",
          comment: "failed to get bricks"
        ) + " \(error)"
      )
      return false
    }
  }

  private func sendBinaryResponse(data: Data, connection: NWConnection) {
    var message = Data()
    let dataSize = Int32(data.count)
    message.append(Data(from: dataSize))
    message.append(data)

    connection.send(content: message, completion: .contentProcessed({ error in
      if let error = error {
        self.logger?.error(
          L(
            "tcpserver_error_send_binary_failed",
            value: "Failed to send binary response:",
            comment: "failed to send binary response"
          ) + " \(error)"
        )
      }
    }))
  }

  private func sendList(
    parameters: ArraySlice<Substring>,
    connection: NWConnection
  ) -> Bool {
    guard expectParameterCount(parameters, equals: 0) else { return false }
    let datasetList = datasets
      .map { "\($0.id) \($0.datasetDescription)" }
      .joined(separator: "\n") + "\n\n"
    connection.send(
      content: datasetList.data(using: .utf8),
      completion: .contentProcessed({ _ in })
    )
    return true
  }

  private func sendInfo(
    parameters: ArraySlice<Substring>,
    connection: NWConnection
  ) -> Bool {
    guard expectParameterCount(parameters, equals: 0) else { return false }

    let kv = KeyValuePairHandler()
    kv.set("VERSION", TCPServer.protocolVersionName)
    kv.set("MAX_BRICKS_PER_GET_REQUEST", maxBricksPerGetRequest)
    let serverInfo = kv.synthesize() + "\n"

    connection.send(
      content: serverInfo.data(using: .utf8),
      completion: .contentProcessed({ _ in })
    )
    return true
  }

  private func closeConnection(for connection: NWConnection) {
    let connectionID = ObjectIdentifier(connection)
    stateLock.lock()
    connectionDatasets.removeValue(forKey: connectionID)
    stateLock.unlock()
  }

  private func appendActiveConnection(_ connection: NWConnection) {
    stateLock.lock()
    activeConnections.append(connection)
    stateLock.unlock()
  }

  private func removeActiveConnection(_ connection: NWConnection) {
    stateLock.lock()
    activeConnections.removeAll(where: { $0 === connection })
    stateLock.unlock()
  }

  private func removeAllActiveConnections() {
    stateLock.lock()
    activeConnections.removeAll()
    stateLock.unlock()
  }

  private func activeConnectionsSnapshot() -> [NWConnection] {
    stateLock.lock()
    let connections = activeConnections
    stateLock.unlock()
    return connections
  }

  private func setConnectionDataset(_ dataset: ConnectionDataset, for connection: NWConnection) {
    let connectionID = ObjectIdentifier(connection)
    stateLock.lock()
    connectionDatasets[connectionID] = dataset
    stateLock.unlock()
  }

  private func connectionDataset(for connection: NWConnection) -> ConnectionDataset? {
    let connectionID = ObjectIdentifier(connection)
    stateLock.lock()
    let dataset = connectionDatasets[connectionID]
    stateLock.unlock()
    return dataset
  }
}

// MARK: - Localized string helper

private func L(_ key: String, value: String, comment: String = "") -> String {
  NSLocalizedString(key, tableName: nil, bundle: .main, value: value, comment: comment)
}

/*
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of Duisburg-
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
