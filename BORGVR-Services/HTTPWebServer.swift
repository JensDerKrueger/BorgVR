import Foundation
import Network
import Security

final class HTTPWebServer {
  private let port: NWEndpoint.Port
  private let queue = DispatchQueue(label: "HTTPWebServerQueue")
  private let datasetServer: TCPServer
  private let authSecret: String
  private let useTLS: Bool
  private let tlsCertificateData: Data
  private let tlsCertificatePassword: String
  private let logger: LoggerBase?

  private var listener: NWListener?
  private var tlsIdentity: sec_identity_t?
  private var activeConnections: [NWConnection] = []
  private let stateLock = NSLock()

  private(set) var isRunning = false

  init(
    port: UInt16,
    datasetServer: TCPServer,
    logger: LoggerBase? = nil,
    authSecret: String? = nil,
    useTLS: Bool = false,
    tlsCertificateData: Data = Data(),
    tlsCertificatePassword: String = ""
  ) {
    self.port = NWEndpoint.Port(rawValue: port) ?? 8080
    self.datasetServer = datasetServer
    self.logger = logger
    self.authSecret = BorgVRServerAuthentication.normalizedSecret(authSecret)
    self.useTLS = useTLS
    self.tlsCertificateData = tlsCertificateData
    self.tlsCertificatePassword = tlsCertificatePassword
  }

  func start() {
    do {
      listener = try NWListener(using: listenerParameters(), on: port)
    } catch {
      logger?.error("Could not create \(schemeName)/WebGPU listener: \(error.localizedDescription)")
      return
    }

    listener?.newConnectionHandler = { [weak self] connection in
      self?.handleNewConnection(connection)
    }
    listener?.start(queue: queue)
    isRunning = true
    logger?.info("\(schemeName)/WebGPU server started on port \(port).")
  }

  func stop() {
    listener?.cancel()
    let connections = activeConnectionsSnapshot()
    connections.forEach { connection in
      connection.cancel()
      removeActiveConnection(connection)
    }
    isRunning = false
    tlsIdentity = nil
    logger?.info("\(schemeName)/WebGPU server stopped.")
  }

  private var schemeName: String {
    useTLS ? "HTTPS" : "HTTP"
  }

  private func listenerParameters() throws -> NWParameters {
    guard useTLS else {
      return .tcp
    }

    let identity = try HTTPWebServerTLSIdentity.create(
      pkcs12Data: tlsCertificateData,
      password: tlsCertificatePassword
    )
    guard let protocolIdentity = sec_identity_create(identity) else {
      throw HTTPWebServerError.tlsIdentityCreationFailed
    }

    tlsIdentity = protocolIdentity
    let tlsOptions = NWProtocolTLS.Options()
    sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, protocolIdentity)

    let tcpOptions = NWProtocolTCP.Options()
    return NWParameters(tls: tlsOptions, tcp: tcpOptions)
  }

  private func handleNewConnection(_ connection: NWConnection) {
    appendActiveConnection(connection)
    connection.stateUpdateHandler = { [weak self, weak connection] state in
      guard let self, let connection else { return }
      switch state {
        case .cancelled, .failed, .waiting:
          self.removeActiveConnection(connection)
        default:
          break
      }
    }
    connection.start(queue: queue)
    receiveRequest(on: connection, data: Data())
  }

  private func receiveRequest(on connection: NWConnection, data: Data) {
    connection.receive(
      minimumIncompleteLength: 1,
      maximumLength: 16 * 1024
    ) { [weak self] chunk, _, isComplete, error in
      guard let self else { return }

      if let error {
        self.logger?.warning("HTTP/WebGPU client disconnected with error: \(error.localizedDescription).")
        connection.cancel()
        self.removeActiveConnection(connection)
        return
      }

      var requestData = data
      if let chunk, !chunk.isEmpty {
        requestData.append(chunk)
      }

      if requestData.isEmpty && isComplete {
        connection.cancel()
        self.removeActiveConnection(connection)
        return
      }

      if requestData.range(of: Data("\r\n\r\n".utf8)) != nil ||
         requestData.range(of: Data("\n\n".utf8)) != nil ||
         isComplete {
        self.handleRequestData(requestData, connection: connection)
      } else {
        self.receiveRequest(on: connection, data: requestData)
      }
    }
  }

  private func handleRequestData(_ data: Data, connection: NWConnection) {
    guard let requestText = String(data: data, encoding: .utf8),
          let request = HTTPRequest(text: requestText)
    else {
      sendError(400, reason: "Bad Request", message: "Invalid HTTP request.", closeAfterSend: true, connection: connection)
      return
    }

    let closeAfterSend = request.shouldCloseConnection

    guard request.method == "GET" || request.method == "HEAD" else {
      sendError(
        405,
        reason: "Method Not Allowed",
        message: "Only GET and HEAD are supported.",
        closeAfterSend: closeAfterSend,
        connection: connection
      )
      return
    }

    guard isAuthorized(request) else {
      sendUnauthorized(closeAfterSend: closeAfterSend, connection: connection)
      return
    }

    let response: HTTPResponse
    do {
      response = try route(request)
    } catch HTTPWebServerError.notFound {
      response = HTTPResponse(
        status: 404,
        reason: "Not Found",
        contentType: "text/plain; charset=utf-8",
        body: Data("Not found.\n".utf8)
      )
    } catch {
      logger?.error("HTTP/WebGPU request failed for \(request.path): \(error.localizedDescription)")
      response = HTTPResponse(
        status: 500,
        reason: "Internal Server Error",
        contentType: "text/plain; charset=utf-8",
        body: Data("Unable to process request.\n".utf8)
      )
    }

    send(response, includeBody: request.method != "HEAD", closeAfterSend: closeAfterSend, connection: connection)
  }

  private func isAuthorized(_ request: HTTPRequest) -> Bool {
    guard !authSecret.isEmpty else { return true }
    guard let authorization = request.header(named: "authorization"),
          authorization.hasPrefix("Basic ")
    else {
      return false
    }

    let encoded = String(authorization.dropFirst("Basic ".count))
    guard let credentialsData = Data(base64Encoded: encoded),
          let credentials = String(data: credentialsData, encoding: .utf8)
    else {
      return false
    }

    let password = credentials.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init) ?? credentials
    return constantTimeEquals(password, authSecret)
  }

  private func route(_ request: HTTPRequest) throws -> HTTPResponse {
    if request.path == "/web-data/datasets.json" {
      return catalogResponse()
    }

    let datasetPrefix = "/web-data/datasets/"
    if request.path.hasPrefix(datasetPrefix) {
      let rest = String(request.path.dropFirst(datasetPrefix.count))
      let parts = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { throw HTTPWebServerError.notFound }

      let datasetID = String(parts[0])
      let tail = String(parts[1])
      if tail == "dataset.json" {
        return try datasetManifestResponse(datasetID: datasetID)
      }

      let bricksPrefix = "bricks/"
      if tail.hasPrefix(bricksPrefix) {
        let brickName = String(tail.dropFirst(bricksPrefix.count))
        return try brickResponse(datasetID: datasetID, brickName: brickName)
      }
    }

    return try staticAssetResponse(path: request.path)
  }

  private func catalogResponse() -> HTTPResponse {
    let datasets = datasetServer.datasetsSnapshot()
    let entries = datasets.map { dataset in
      let name = displayName(for: dataset)
      return WebCatalogDataset(
        catalogID: "\(dataset.id)#server",
        id: dataset.id,
        name: name,
        description: dataset.datasetDescription.isEmpty ? name : dataset.datasetDescription,
        metadata: "datasets/\(dataset.id)/dataset.json",
        variant: "server"
      )
    }

    let catalog = WebCatalog(
      format: "borgvr-web-catalog",
      version: 1,
      generatedAt: "dynamic",
      datasets: entries
    )
    return jsonResponse(catalog)
  }

  private func datasetManifestResponse(datasetID: String) throws -> HTTPResponse {
    guard let info = datasetServer.findDatasetById(datasetID) else {
      throw HTTPWebServerError.notFound
    }

    let dataset = try BORGVRFileData(filename: info.filename)
    let metadata = dataset.getMetadata()
    let levels = metadata.levelMetadata.enumerated().map { index, level in
      WebDatasetLevel(
        level: index,
        size: [level.size.x, level.size.y, level.size.z],
        brickCount: [level.totalBricks.x, level.totalBricks.y, level.totalBricks.z],
        brickTotal: level.totalBricks.x * level.totalBricks.y * level.totalBricks.z,
        firstBrick: level.prevBricks
      )
    }

    let bricks = metadata.brickMetadata.enumerated().map { index, brick in
      let (levelIndex, coord) = brickCoordinate(index: index, levels: metadata.levelMetadata)
      return WebDatasetBrick(
        index: index,
        level: levelIndex,
        coord: coord,
        min: brick.minValue,
        max: brick.maxValue,
        byteLength: brick.size
      )
    }

    let manifest = WebDatasetManifest(
      format: "borgvr-web-dataset",
      version: 1,
      id: metadata.uniqueID,
      name: displayName(for: info),
      description: info.datasetDescription,
      metaDescription: metadata.metaDescription,
      variant: metadata.compression ? "lz4" : "uncompressed",
      volume: WebDatasetVolume(
        size: [metadata.width, metadata.height, metadata.depth],
        aspect: [metadata.aspectX, metadata.aspectY, metadata.aspectZ],
        componentCount: metadata.componentCount,
        bytesPerComponent: metadata.bytesPerComponent,
        valueType: "uint",
        endianness: "little",
        valueRange: [metadata.minValue, metadata.maxValue],
        dataRange: [0, metadata.rangeMax]
      ),
      bricking: WebDatasetBricking(
        brickSize: metadata.brickSize,
        overlap: metadata.overlap,
        indexing: "borgvr-linear",
        brickOrder: "x-fastest-y-z",
        compression: metadata.compression ? "lz4" : "none",
        supportedCompressions: ["none", "lz4"]
      ),
      levels: levels,
      bricks: bricks
    )
    return jsonResponse(manifest)
  }

  private func brickResponse(datasetID: String, brickName: String) throws -> HTTPResponse {
    guard let info = datasetServer.findDatasetById(datasetID),
          let brickIndex = Int(brickName)
    else {
      throw HTTPWebServerError.notFound
    }

    let dataset = try BORGVRFileData(filename: info.filename)
    let metadata = dataset.getMetadata()
    guard brickIndex >= 0, brickIndex < metadata.brickMetadata.count else {
      throw HTTPWebServerError.notFound
    }

    let brick = metadata.brickMetadata[brickIndex]
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: brick.size)
    defer { buffer.deallocate() }
    try dataset.getRawBrick(brickMeta: brick, outputBuffer: buffer)
    let body = Data(bytes: buffer, count: brick.size)
    return HTTPResponse(status: 200, reason: "OK", contentType: "application/octet-stream", body: body)
  }

  private func staticAssetResponse(path: String) throws -> HTTPResponse {
    guard let url = WebAssetProvider.url(for: path),
          url.isFileURL,
          let rootURL = WebAssetProvider.rootURL()
    else {
      throw HTTPWebServerError.notFound
    }

    let standardizedRoot = rootURL.standardizedFileURL.path
    let standardizedPath = url.standardizedFileURL.path
    guard standardizedPath == standardizedRoot || standardizedPath.hasPrefix(standardizedRoot + "/") else {
      throw HTTPWebServerError.notFound
    }

    let body = try Data(contentsOf: url)
    return HTTPResponse(status: 200, reason: "OK", contentType: WebAssetProvider.contentType(for: url.path), body: body)
  }

  private func jsonResponse<T: Encodable>(_ value: T) -> HTTPResponse {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let body = (try? encoder.encode(value)) ?? Data("{}".utf8)
    return HTTPResponse(status: 200, reason: "OK", contentType: "application/json; charset=utf-8", body: body)
  }

  private func sendError(
    _ status: Int,
    reason: String,
    message: String,
    closeAfterSend: Bool = false,
    connection: NWConnection
  ) {
    let response = HTTPResponse(
      status: status,
      reason: reason,
      contentType: "text/plain; charset=utf-8",
      body: Data("\(message)\n".utf8)
    )
    send(response, closeAfterSend: closeAfterSend, connection: connection)
  }

  private func sendUnauthorized(closeAfterSend: Bool = false, connection: NWConnection) {
    let response = HTTPResponse(
      status: 401,
      reason: "Unauthorized",
      contentType: "text/plain; charset=utf-8",
      body: Data("A BorgVR server password is required.\n".utf8),
      headers: [("WWW-Authenticate", "Basic realm=\"BorgVR Dataset Server\"")]
    )
    send(response, closeAfterSend: closeAfterSend, connection: connection)
  }

  private func send(
    _ response: HTTPResponse,
    includeBody: Bool = true,
    closeAfterSend: Bool = false,
    connection: NWConnection
  ) {
    var header = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
    header += "Content-Type: \(response.contentType)\r\n"
    header += "Content-Length: \(response.body.count)\r\n"
    header += "Connection: \(closeAfterSend ? "close" : "keep-alive")\r\n"
    if !closeAfterSend {
      header += "Keep-Alive: timeout=15, max=1000\r\n"
    }
    header += "Access-Control-Allow-Origin: *\r\n"
    for (name, value) in response.headers {
      header += "\(name): \(value)\r\n"
    }
    header += "\r\n"

    var data = Data(header.utf8)
    if includeBody {
      data.append(response.body)
    }
    connection.send(
      content: data,
      contentContext: .defaultMessage,
      isComplete: closeAfterSend,
      completion: .contentProcessed { [weak self, weak connection] error in
        guard let self, let connection else { return }
        if let error {
          self.logger?.warning("\(self.schemeName)/WebGPU response send failed: \(error.localizedDescription)")
          connection.cancel()
          self.removeActiveConnection(connection)
          return
        }
        if closeAfterSend {
          self.removeActiveConnection(connection)
        } else {
          self.receiveRequest(on: connection, data: Data())
        }
      })
  }

  private func brickCoordinate(index: Int, levels: [LevelMetadata]) -> (level: Int, coord: [Int]) {
    for (levelIndex, level) in levels.enumerated() {
      let total = level.totalBricks.x * level.totalBricks.y * level.totalBricks.z
      guard index >= level.prevBricks, index < level.prevBricks + total else {
        continue
      }

      let localIndex = index - level.prevBricks
      let x = localIndex % level.totalBricks.x
      let y = (localIndex / level.totalBricks.x) % level.totalBricks.y
      let z = localIndex / (level.totalBricks.x * level.totalBricks.y)
      return (levelIndex, [x, y, z])
    }

    return (0, [0, 0, 0])
  }

  private func displayName(for dataset: DatasetInfo) -> String {
    if !dataset.datasetDescription.isEmpty {
      return dataset.datasetDescription
    }
    return URL(fileURLWithPath: dataset.filename).deletingPathExtension().lastPathComponent
  }

  private func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
    let lhsBytes = [UInt8](lhs.utf8)
    let rhsBytes = [UInt8](rhs.utf8)
    var difference = lhsBytes.count ^ rhsBytes.count
    let count = min(lhsBytes.count, rhsBytes.count)
    for index in 0..<count {
      difference |= Int(lhsBytes[index] ^ rhsBytes[index])
    }
    return difference == 0
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

  private func activeConnectionsSnapshot() -> [NWConnection] {
    stateLock.lock()
    let connections = activeConnections
    stateLock.unlock()
    return connections
  }
}

private struct HTTPRequest {
  let method: String
  let target: String
  let version: String
  let path: String
  let headers: [(String, String)]

  init?(text: String) {
    let lines = text.components(separatedBy: .newlines)
    guard let requestLine = lines.first else { return nil }
    let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
    guard parts.count >= 2 else { return nil }

    method = parts[0]
    target = parts[1]
    version = parts.count >= 3 ? parts[2].uppercased() : "HTTP/1.0"
    path = HTTPRequest.normalizedPath(target)
    headers = lines.dropFirst().compactMap { line in
      guard let separator = line.firstIndex(of: ":") else { return nil }
      let name = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
      return name.isEmpty ? nil : (name, value)
    }
  }

  func header(named name: String) -> String? {
    let normalizedName = name.lowercased()
    return headers.first(where: { $0.0 == normalizedName })?.1
  }

  var shouldCloseConnection: Bool {
    let connectionHeader = header(named: "connection")?.lowercased() ?? ""
    if connectionHeader
      .split(separator: ",")
      .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
      .contains("close") {
      return true
    }
    if version == "HTTP/1.0" {
      return !connectionHeader
        .split(separator: ",")
        .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        .contains("keep-alive")
    }
    return false
  }

  private static func normalizedPath(_ target: String) -> String {
    let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "/"
    let decoded = path.removingPercentEncoding ?? path
    return decoded.isEmpty ? "/" : decoded
  }
}

private struct HTTPResponse {
  let status: Int
  let reason: String
  let contentType: String
  let body: Data
  var headers: [(String, String)] = []
}

private enum HTTPWebServerError: Error {
  case notFound
  case tlsIdentityCreationFailed
}

private struct WebCatalog: Encodable {
  let format: String
  let version: Int
  let generatedAt: String
  let datasets: [WebCatalogDataset]
}

private struct WebCatalogDataset: Encodable {
  let catalogID: String
  let id: String
  let name: String
  let description: String
  let metadata: String
  let variant: String
}

private struct WebDatasetManifest: Encodable {
  let format: String
  let version: Int
  let id: String
  let name: String
  let description: String
  let metaDescription: String
  let variant: String
  let volume: WebDatasetVolume
  let bricking: WebDatasetBricking
  let levels: [WebDatasetLevel]
  let bricks: [WebDatasetBrick]
}

private struct WebDatasetVolume: Encodable {
  let size: [Int]
  let aspect: [Float]
  let componentCount: Int
  let bytesPerComponent: Int
  let valueType: String
  let endianness: String
  let valueRange: [Int]
  let dataRange: [Int]
}

private struct WebDatasetBricking: Encodable {
  let brickSize: Int
  let overlap: Int
  let indexing: String
  let brickOrder: String
  let compression: String
  let supportedCompressions: [String]
}

private struct WebDatasetLevel: Encodable {
  let level: Int
  let size: [Int]
  let brickCount: [Int]
  let brickTotal: Int
  let firstBrick: Int
}

private struct WebDatasetBrick: Encodable {
  let index: Int
  let level: Int
  let coord: [Int]
  let min: Int
  let max: Int
  let byteLength: Int
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
