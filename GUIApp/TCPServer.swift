import Network
import Foundation

class TCPServer {
  let port: NWEndpoint.Port
  let queue = DispatchQueue(label: "TCPServerQueue")
  var listener: NWListener?
  var activeConnections: [NWConnection] = []
  var isRunning = false
  var logger: LoggerBase?

  /// Dataset list received from the GUI
  private var datasets: [DatasetInfo]
  private var connectionDatasets: [ObjectIdentifier: (dataset: BORGVRFileData, buffer: UnsafeMutablePointer<UInt8>)] = [:]

  init(port: UInt16, logger: LoggerBase? = nil, datasets: [DatasetInfo] = []) {
    self.port = NWEndpoint.Port(rawValue: port)!
    self.logger = logger
    self.datasets = datasets
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
    logger?.info("Server started on port \(port)")
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
    activeConnections.append(connection)
    receiveLine(on: connection, buffer: "")
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

#if DEBUG
        if case let .hostPort(host, _) = connection.endpoint {
          let clientAddress = host.debugDescription
          logger?.dev("Received from \(clientAddress): \(request)")
        } else {
          logger?.dev("Received: \(request)")
        }
#endif

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

    switch cmd.uppercased() {
      case "LIST":
        let datasetList = datasets.map { "\($0.id) \($0.datasetDescription)" }.joined(separator: "\n") + "\n\n"
        connection.send(content: datasetList.data(using: .utf8), completion: .contentProcessed({ _ in }))
        return true
      case "OPEN":
        return openDataset(components.dropFirst().first, connection: connection)
      case "GETBRICK":
        return getBrick(components.dropFirst().first, connection: connection)
      default:
        return false
    }
  }

  private func openDataset(_ idString: Substring?, connection: NWConnection) -> Bool {
    guard let idString = idString, let id = Int(idString), let dataset = datasets.first(where: { $0.id == id }) else {
      return false
    }

    let connectionID = ObjectIdentifier(connection)
    if let existingDataset = connectionDatasets[connectionID] {
      logger?.info("Closing previous dataset for connection")
      existingDataset.buffer.deallocate()
      connectionDatasets[connectionID] = nil
    }

    if let data = try? BORGVRFileData(filename: dataset.filename) {
      let buffer = data.allocateBrickBuffer()
      connectionDatasets[connectionID] = (dataset: data, buffer: buffer)

      let filename = URL(fileURLWithPath: dataset.filename).lastPathComponent
      if case let .hostPort(host, _) = connection.endpoint {
        let clientAddress = host.debugDescription
        logger?.info("Opened dataset \(filename) for \(clientAddress) ID=\(connectionID.hashValue)")
      } else {
        logger?.info("Opened dataset \(filename) ID=\(connectionID.hashValue)")
      }

      sendBinaryResponse(data.getMetadata().toData(), connection: connection)
      return true
    } else {
      logger?.error("Failed to open dataset \(id)")
      return false
    }
  }

  private func getBrick(_ indexString: Substring?, connection: NWConnection) -> Bool {
    guard let indexString = indexString, let index = Int(indexString) else {
      return false
    }

    let connectionID = ObjectIdentifier(connection)
    guard let datasetEntry = connectionDatasets[connectionID] else {
      return false
    }

    do {
      let brickMeta = datasetEntry.dataset.getMetadata().brickMetadata[index]
      try datasetEntry.dataset.getRawBrick(brickMeta: brickMeta, outputBuffer: datasetEntry.buffer)

#if DEBUG
      logger?.dev("Sending Brick of length \(brickMeta.size) at index \(index)")
#endif

      sendBinaryResponse(Data(bytes: datasetEntry.buffer, count: brickMeta.size), connection: connection)
      return true
    } catch {
      logger?.error("Failed to get brick at index \(index)")
      return false
    }
  }

  private func sendBinaryResponse(_ data: Data, connection: NWConnection) {
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

  private func closeConnection(for connection: NWConnection) {
    let connectionID = ObjectIdentifier(connection)
    if let datasetEntry = connectionDatasets[connectionID] {
      datasetEntry.buffer.deallocate()
    }
    connectionDatasets[connectionID] = nil
  }
}
