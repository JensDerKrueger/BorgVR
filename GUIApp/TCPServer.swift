import Network
import Foundation

class TCPServer {
  static let protocolVersionName : String = "1"
  
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

  init(port: UInt16, maxBricksPerGetRequest: Int, logger: LoggerBase? = nil, datasets: [DatasetInfo] = []) {
    self.port = NWEndpoint.Port(rawValue: port)!
    self.logger = logger
    self.datasets = datasets
    self.maxBricksPerGetRequest = maxBricksPerGetRequest
  }

  func start() {
    do {
      listener = try NWListener(using: .tcp, on: port)
    } catch {
      logger?.error("Failed to create listener: \(error)")
      return
    }

    listener?.newConnectionHandler = { [weak self] connection in
      self?.handleNewConnection(connection)
    }

    listener?.start(queue: queue)
    isRunning = true
    logger?
      .info(
        "Server with protocol version \(TCPServer.protocolVersionName) started on port \(port)"
      )
  }

  func stop() {
    listener?.cancel()
    activeConnections.forEach { connection in
      closeConnection(for: connection)
      connection.cancel()
    }
    activeConnections.removeAll()
    isRunning = false
    logger?.info("Server stopped.")
  }

  private func handleNewConnection(_ connection: NWConnection) {
    activeConnections.append(connection)

    connection.stateUpdateHandler = { [weak self] state in
      switch state {
        case .cancelled, .waiting, .failed(_):
          self?.closeConnection(for: connection)
          self?.activeConnections.removeAll(where: { $0 === connection })
        default:
          break
      }
    }
    connection.start(queue: queue)
    receiveLine(on: connection, buffer: "")
  }
  
  // MARK: - Parameter validation helpers
  private func expectParameterCount(_ parameters: ArraySlice<Substring>, equals expected: Int) -> Bool {
    return parameters.count == expected
  }

  private func expectParameterCount(_ parameters: ArraySlice<Substring>, in range: ClosedRange<Int>) -> Bool {
    return parameters.count >= range.lowerBound && parameters.count <= range.upperBound
  }

  private func receiveLine(on connection: NWConnection, buffer: String) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, isComplete, error in
      guard let self = self else { return }

      if let error = error {
        self.logger?.warning("Client disconnected with error: \(error)")
        self.closeConnection(for: connection)
        return
      }

      guard let data = data, !data.isEmpty else {
        if isComplete {
          self.logger?.info("Client disconnected normally.")
          self.closeConnection(for: connection)
        }
        return
      }

      var newBuffer = buffer + String(decoding: data, as: UTF8.self)

      while let newlineRange = newBuffer.range(of: "\n") {
        let request = newBuffer[..<newlineRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        newBuffer = String(newBuffer[newlineRange.upperBound...])

        if !self.processCommand(request, connection: connection) {
          connection.cancel()
          return
        }
      }

      if isComplete {
        connection.cancel()
        self.logger?.info("Closing connection after processing.")
        self.closeConnection(for: connection)
      } else {
        self.receiveLine(on: connection, buffer: newBuffer)
      }
    }
  }

  private func processCommand(_ command: String, connection: NWConnection) -> Bool {
    let components = command.split(separator: " ")
    guard let cmd = components.first else {
      return false
    }

    let parameters = components.dropFirst()

    switch cmd.uppercased() {
      case "LIST":
        return sendList(parameters: parameters, connection: connection)

      case "OPEN":
        return openDataset(parameters:parameters, connection: connection)

      case "GETBRICKS":
        return getBricks(parameters: parameters, connection: connection)
      
      case "INFO":
        return sendInfo(parameters: parameters, connection: connection)

      default:
        return false
    }
  }

  private func openDataset(parameters: ArraySlice<Substring>, connection: NWConnection) -> Bool {
    guard expectParameterCount(parameters, equals: 1) else { return false }

    guard let idString = parameters.first, let dataset = datasets.first(where: { $0.id == idString }) else {
      return false
    }

    let connectionID = ObjectIdentifier(connection)
    if connectionDatasets[connectionID] != nil {
      logger?.info("Closing previous dataset for connection")
      connectionDatasets[connectionID] = nil
    }

    if let data = try? BORGVRFileData(filename: dataset.filename) {
      connectionDatasets[connectionID] = ConnectionDataset(dataset: data)

      let filename = URL(fileURLWithPath: dataset.filename).lastPathComponent
      if case let .hostPort(host, _) = connection.endpoint {
        let clientAddress = host.debugDescription
        logger?.info("Opened dataset \(filename) for \(clientAddress) ID=\(connectionID.hashValue)")
      } else {
        logger?.info("Opened dataset \(filename) ID=\(connectionID.hashValue)")
      }

      sendBinaryResponse(data: data.getMetadata().toData(), connection: connection)
      return true
    } else {
      logger?.error("Failed to open dataset \(idString)")
      return false
    }
  }

  private func convertToInts(_ indexStrings: ArraySlice<Substring>) -> [Int]? {
    let ints = indexStrings.compactMap { Int($0) }
    return ints.count == indexStrings.count ? ints : nil
  }

  private func getBricks(parameters indexStrings: ArraySlice<Substring>, connection: NWConnection) -> Bool {
    guard expectParameterCount(indexStrings, in: 1...Int(maxBricksPerGetRequest)) else { return false }

    guard let indices = convertToInts(indexStrings), indices.count <= maxBricksPerGetRequest else {
      return false
    }

    let connectionID = ObjectIdentifier(connection)
    guard let datasetEntry = connectionDatasets[connectionID] else {
      return false
    }

    var totalSize = 0
    for index in indices {
      let brickMeta = datasetEntry.dataset.getMetadata().brickMetadata[index]
      totalSize += brickMeta.size
    }

    do {
      var brickData = Data(capacity: totalSize)
      for index in indices {
        let brickMeta = datasetEntry.dataset.getMetadata().brickMetadata[index]
        try datasetEntry.dataset.getRawBrick(brickMeta: brickMeta, outputBuffer: datasetEntry.buffer)
        brickData.append(Data(bytes: datasetEntry.buffer, count: brickMeta.size))
      }
      sendBinaryResponse(data: brickData, connection: connection)
      return true
    } catch {
      logger?.error("Failed to get bricks: \(error)")
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
        self.logger?.error("Failed to send binary response: \(error)")
      }
    }))
  }

  private func sendList(parameters: ArraySlice<Substring>, connection: NWConnection) -> Bool {
    guard expectParameterCount(parameters, equals: 0) else { return false }
    let datasetList = datasets.map { "\($0.id) \($0.datasetDescription)" }.joined(separator: "\n") + "\n\n"
    connection.send(content: datasetList.data(using: .utf8), completion: .contentProcessed({ _ in }))
    return true
  }
  
  private func sendInfo(parameters: ArraySlice<Substring>, connection: NWConnection) -> Bool {
    guard expectParameterCount(parameters, equals: 0) else { return false }

    let kv = KeyValuePairHandler()
    kv.set("VERSION",TCPServer.protocolVersionName)
    kv.set("MAX_BRICKS_PER_GET_REQUEST",maxBricksPerGetRequest)
    let serverInfo = kv.synthesize() + "\n"

    connection.send(content: serverInfo.data(using: .utf8), completion: .contentProcessed({ _ in }))
    return true
  }

  private func closeConnection(for connection: NWConnection) {
    let connectionID = ObjectIdentifier(connection)
    connectionDatasets[connectionID] = nil
  }
}

