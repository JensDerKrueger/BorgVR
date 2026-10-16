import Combine
import Foundation
import Network
import Security

@MainActor
final class BorgVRMCPServerController: ObservableObject {
  @Published private(set) var isRunning = false
  @Published private(set) var statusText = String(localized: "MCP server is not started.")

  private var server: BorgVRMCPServer?
  private var commandService: (any BorgVRMCPCommandService)?
  private var configuration: BorgVRMCPConfiguration?
  private var logger: LoggerBase?
  private var serverGeneration = 0

  func configure(
    commandService: any BorgVRMCPCommandService,
    logger: LoggerBase?
  ) {
    self.commandService = commandService
    self.logger = logger
  }

  func apply(_ configuration: BorgVRMCPConfiguration) {
    guard configuration.enabled else {
      stop()
      return
    }
    guard commandService != nil else {
      statusText = String(localized: "MCP command service is not available.")
      return
    }
    guard !configuration.allowRemoteConnections ||
            !configuration.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      stop()
      statusText = String(
        localized: "An access token is required before remote MCP connections can be enabled."
      )
      return
    }
    if self.configuration == configuration,
       let server,
       server.lastError == nil {
      return
    }
    if let currentConfiguration = self.configuration,
       currentConfiguration.hasSameListenerConfiguration(as: configuration),
       let server,
       server.lastError == nil {
      server.updateAccessToken(configuration.accessToken)
      self.configuration = configuration
      statusText = statusDescription(for: configuration)
      return
    }
    start(configuration)
  }

  func stop() {
    serverGeneration += 1
    server?.stop()
    server = nil
    configuration = nil
    isRunning = false
    statusText = String(localized: "MCP server is not started.")
  }

  private func start(_ configuration: BorgVRMCPConfiguration) {
    server?.stop()
    guard let commandService else { return }
    serverGeneration += 1
    let generation = serverGeneration

    let newServer = BorgVRMCPServer(
      configuration: configuration,
      commandService: commandService,
      logger: logger,
      stateDidChange: { [weak self] running, error in
        Task { @MainActor [weak self] in
          guard let self,
                self.serverGeneration == generation,
                let activeConfiguration = self.configuration else { return }
          self.isRunning = running
          if let error {
            self.statusText = error
          } else if running {
            self.statusText = self.statusDescription(for: activeConfiguration)
          }
        }
      }
    )
    server = newServer
    self.configuration = configuration
    newServer.start()
    isRunning = newServer.isRunning
    if let error = newServer.lastError {
      statusText = error
    } else {
      statusText = statusDescription(for: configuration)
    }
  }

  private func statusDescription(for configuration: BorgVRMCPConfiguration) -> String {
    let scope = configuration.allowRemoteConnections
      ? String(localized: "network")
      : "localhost"
    return String(
      format: String(localized: "MCP server on %@, port %d"),
      scope,
      Int(configuration.normalizedPort)
    )
  }
}

final class BorgVRMCPServer: @unchecked Sendable {
  private static let protocolVersion = "2026-07-28"
  private static let legacyProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
  private static let supportedProtocolVersions = [protocolVersion] + legacyProtocolVersions
  private static let maximumRequestBytes = 4 * 1024 * 1024
  private static let maximumConnections = 16

  private let configuration: BorgVRMCPConfiguration
  private weak var commandService: (any BorgVRMCPCommandService)?
  private var logger: LoggerBase?
  private let stateDidChange: @Sendable (Bool, String?) -> Void
  private let queue = DispatchQueue(label: "BorgVRMCPServer")
  private let connectionLock = NSLock()
  private let authenticationLock = NSLock()
  private var connections: [NWConnection] = []
  private var listener: NWListener?
  private var tlsIdentity: sec_identity_t?
  private var accessToken: String

  private(set) var isRunning = false
  private(set) var lastError: String?

  init(
    configuration: BorgVRMCPConfiguration,
    commandService: any BorgVRMCPCommandService,
    logger: LoggerBase?,
    stateDidChange: @escaping @Sendable (Bool, String?) -> Void
  ) {
    self.configuration = configuration
    self.commandService = commandService
    self.logger = logger
    self.stateDidChange = stateDidChange
    accessToken = configuration.accessToken
  }

  func updateAccessToken(_ accessToken: String) {
    authenticationLock.lock()
    self.accessToken = accessToken
    authenticationLock.unlock()
  }

  func start() {
    lastError = nil
    do {
      if configuration.allowRemoteConnections,
         configuration.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw BorgVRMCPServerError.remoteAccessRequiresToken
      }
      let parameters = try listenerParameters()
      let port = NWEndpoint.Port(rawValue: configuration.normalizedPort) ?? 8765
      let listener = try NWListener(using: parameters, on: port)
      listener.newConnectionHandler = { [weak self] connection in
        self?.accept(connection)
      }
      listener.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        switch state {
          case .ready:
            self.isRunning = true
            self.stateDidChange(true, nil)
          case .failed(let error):
            self.lastError = "MCP server failed: \(error.localizedDescription)"
            self.logger?.error(self.lastError ?? "MCP server failed.")
            self.isRunning = false
            self.stateDidChange(false, self.lastError)
          case .cancelled:
            self.isRunning = false
            self.stateDidChange(false, nil)
          default:
            break
        }
      }
      self.listener = listener
      listener.start(queue: queue)
      logger?.info(
        "MCP \(configuration.scheme.uppercased()) server started on port \(configuration.normalizedPort)."
      )
    } catch {
      lastError = error.localizedDescription
      logger?.error(error.localizedDescription)
      isRunning = false
      stateDidChange(false, lastError)
    }
  }

  func stop() {
    listener?.cancel()
    listener = nil
    let active = withConnectionLock { () -> [NWConnection] in
      defer { connections.removeAll() }
      return connections
    }
    active.forEach { $0.cancel() }
    tlsIdentity = nil
    if isRunning {
      logger?.info("MCP server stopped.")
    }
    isRunning = false
  }

  private func listenerParameters() throws -> NWParameters {
    guard configuration.usesTLS else {
      let parameters = NWParameters.tcp
      guard let address = IPv4Address("127.0.0.1") else {
        throw BorgVRMCPServerError.localhostBindingFailed
      }
      parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(address), port: .any)
      return parameters
    }

    let identity = try HTTPWebServerTLSIdentity.create(
      pkcs12Data: configuration.tlsCertificateData,
      password: configuration.tlsCertificatePassword,
      commonName: "BorgVR MCP Server"
    )
    guard let protocolIdentity = sec_identity_create(identity) else {
      throw BorgVRMCPServerError.tlsIdentityCreationFailed
    }
    tlsIdentity = protocolIdentity

    let tlsOptions = NWProtocolTLS.Options()
    sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, protocolIdentity)
    return NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
  }

  private func accept(_ connection: NWConnection) {
    let accepted = withConnectionLock { () -> Bool in
      guard connections.count < Self.maximumConnections else { return false }
      connections.append(connection)
      return true
    }
    guard accepted else {
      connection.cancel()
      return
    }

    connection.stateUpdateHandler = { [weak self, weak connection] state in
      guard let self, let connection else { return }
      switch state {
        case .failed, .cancelled:
          self.remove(connection)
        default:
          break
      }
    }
    connection.start(queue: queue)
    receive(on: connection, accumulated: Data())
  }

  private func receive(on connection: NWConnection, accumulated: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
      [weak self] data, _, complete, error in
      guard let self else { return }
      if error != nil {
        connection.cancel()
        self.remove(connection)
        return
      }

      var requestData = accumulated
      if let data { requestData.append(data) }
      guard requestData.count <= Self.maximumRequestBytes else {
        self.sendHTTP(status: 413, body: Data(), connection: connection)
        return
      }

      if let request = MCPHTTPRequest.parse(requestData) {
        guard requestData.count >= request.totalByteCount else {
          self.receive(on: connection, accumulated: requestData)
          return
        }
        Task { [weak self] in
          await self?.handle(request, connection: connection)
        }
      } else if complete {
        self.sendHTTP(status: 400, body: Data(), connection: connection)
      } else {
        self.receive(on: connection, accumulated: requestData)
      }
    }
  }

  private func handle(_ request: MCPHTTPRequest, connection: NWConnection) async {
    guard request.method == "POST", request.path == "/mcp" else {
      sendHTTP(status: request.method == "POST" ? 404 : 405, body: Data(), connection: connection)
      return
    }
    guard originIsAllowed(request.headers["origin"]) else {
      sendHTTP(status: 403, body: Data(), connection: connection)
      return
    }
    guard isAuthorized(request.headers["authorization"]) else {
      sendHTTP(
        status: 401,
        body: Data(),
        extraHeaders: ["WWW-Authenticate": "Bearer"],
        connection: connection
      )
      return
    }
    guard let object = try? JSONSerialization.jsonObject(with: request.body),
          let json = object as? [String: Any],
          json["jsonrpc"] as? String == "2.0",
          let method = json["method"] as? String else {
      sendJSON(errorResponse(id: nil, code: -32_700, message: "Parse error"), connection: connection)
      return
    }

    let id = json["id"]
    let parameters = json["params"] as? [String: Any]
    let requestedVersion = request.headers["mcp-protocol-version"]
      ?? ((parameters?["_meta"] as? [String: Any])?["io.modelcontextprotocol/protocolVersion"] as? String)
    let isModernRequest = requestedVersion == Self.protocolVersion || method == "server/discover"

    if let requestedVersion, !Self.supportedProtocolVersions.contains(requestedVersion) {
      sendJSON(
        errorResponse(
          id: id,
          code: -32_022,
          message: "Unsupported protocol version.",
          data: ["requested": requestedVersion, "supported": Self.supportedProtocolVersions]
        ),
        status: 400,
        connection: connection
      )
      return
    }
    if isModernRequest,
       let validationError = validateModernHeaders(
         request.headers,
         method: method,
         parameters: parameters
       ) {
      sendJSON(
        errorResponse(id: id, code: -32_020, message: validationError),
        status: 400,
        connection: connection
      )
      return
    }

    if id == nil {
      sendHTTP(status: 202, body: Data(), connection: connection)
      return
    }

    do {
      let result = try await dispatch(
        method: method,
        parameters: parameters,
        modern: isModernRequest
      )
      sendJSON(
        [
          "jsonrpc": "2.0",
          "id": id ?? NSNull(),
          "result": isModernRequest ? modernResult(result) : result
        ],
        connection: connection
      )
    } catch BorgVRMCPServerError.methodNotFound {
      sendJSON(
        errorResponse(id: id, code: -32_601, message: "Method not found."),
        connection: connection
      )
    } catch {
      sendJSON(
        errorResponse(id: id, code: -32_602, message: error.localizedDescription),
        connection: connection
      )
    }
  }

  private func dispatch(
    method: String,
    parameters: [String: Any]?,
    modern: Bool
  ) async throws -> Any {
    switch method {
      case "server/discover":
        guard modern else { throw BorgVRMCPServerError.methodNotFound(method) }
        return [
          "supportedVersions": Self.supportedProtocolVersions,
          "capabilities": ["tools": ["listChanged": false]],
          "instructions": "Inspect and control the visualization currently open in BorgVR.",
          "ttlMs": 0,
          "cacheScope": "private"
        ]
      case "initialize":
        guard !modern else { throw BorgVRMCPServerError.methodNotFound(method) }
        let requested = ((parameters?["protocolVersion"] as? String).flatMap {
          Self.legacyProtocolVersions.contains($0) ? $0 : nil
        }) ?? Self.legacyProtocolVersions[0]
        return [
          "protocolVersion": requested,
          "capabilities": ["tools": ["listChanged": false]],
          "serverInfo": [
            "name": "BorgVR",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
          ]
        ]
      case "ping":
        return [:]
      case "tools/list":
        var result: [String: Any] = ["tools": toolDefinitions]
        if modern {
          result["ttlMs"] = 0
          result["cacheScope"] = "private"
        }
        return result
      case "tools/call":
        guard let name = parameters?["name"] as? String else {
          throw BorgVRMCPCommandError.invalidArgument("Missing tool name.")
        }
        let arguments = parameters?["arguments"] as? [String: Any] ?? [:]
        do {
          return try await callTool(name: name, arguments: arguments)
        } catch {
          return [
            "content": [["type": "text", "text": error.localizedDescription]],
            "isError": true
          ]
        }
      default:
        throw BorgVRMCPServerError.methodNotFound(method)
    }
  }

  private func callTool(name: String, arguments: [String: Any]) async throws -> [String: Any] {
    guard let service = commandService else {
      throw BorgVRMCPCommandError.rendererUnavailable
    }

    switch name {
      case "list_datasets":
        return structuredToolResult(try await service.listDatasets())
      case "open_dataset":
        try await service.openDataset(id: try string("id", in: arguments))
        return structuredToolResult(await service.applicationState())
      case "close_dataset":
        try await service.closeDataset()
        return structuredToolResult(await service.applicationState())
      case "get_application_state":
        let state = await service.applicationState()
        return structuredToolResult(state)
      case "set_render_mode":
        let mode = try string("mode", in: arguments)
        try await service.setRenderMode(mode)
        return structuredToolResult(await service.applicationState())
      case "set_transform":
        let rotation = try optionalVector4("rotation", in: arguments)
        let translation = try optionalVector3("translation", in: arguments)
        let scale = try optionalVector3("scale", in: arguments)
        try await service.setTransform(rotation: rotation, translation: translation, scale: scale)
        return structuredToolResult(await service.applicationState())
      case "rotate_view":
        let axis = try vector3("axis", in: arguments)
        let degrees = try float("degrees", in: arguments)
        try await service.rotate(axis: axis, degrees: degrees)
        return structuredToolResult(await service.applicationState())
      case "set_iso_value":
        try await service.setNormalizedIsoValue(try float("value", in: arguments))
        return structuredToolResult(await service.applicationState())
      case "set_clipping":
        let minimum = try vector3("minimum", in: arguments)
        let maximum = try vector3("maximum", in: arguments)
        try await service.setClipping(minimum: minimum, maximum: maximum)
        return structuredToolResult(await service.applicationState())
      case "set_lighting":
        try await service.setLighting(
          direction: try optionalVector3("direction", in: arguments),
          ambient: try optionalVector3("ambient", in: arguments),
          diffuse: try optionalVector3("diffuse", in: arguments),
          specular: try optionalVector3("specular", in: arguments)
        )
        return structuredToolResult(await service.applicationState())
      case "set_annotation_visibility":
        try await service.setAnnotationVisibility(
          objects: try optionalBool("objects", in: arguments),
          measurements: try optionalBool("measurements", in: arguments)
        )
        return structuredToolResult(await service.applicationState())
      case "reset_state":
        let rawScope = arguments["scope"] as? String ?? BorgVRMCPResetScope.all.rawValue
        guard let scope = BorgVRMCPResetScope(rawValue: rawScope) else {
          throw BorgVRMCPCommandError.invalidArgument("Unknown reset scope.")
        }
        try await service.reset(scope)
        return structuredToolResult(await service.applicationState())
      case "wait_until_rendered":
        let state = await service.applicationState()
        let frame = (arguments["after_frame"] as? NSNumber)?.uint64Value ?? state.completedFrame
        let timeout = min(max((arguments["timeout_seconds"] as? NSNumber)?.doubleValue ?? 10, 0.1), 120)
        try await service.waitUntilRendered(after: frame, timeout: timeout)
        return structuredToolResult(await service.applicationState())
      case "capture_screenshot":
        let image = try await service.captureScreenshot()
        let metadata: [String: Any] = [
          "width": image.width,
          "height": image.height,
          "renderedFrame": image.renderedFrame
        ]
        return [
          "content": [
            [
              "type": "image",
              "data": image.pngData.base64EncodedString(),
              "mimeType": "image/png"
            ]
          ],
          "structuredContent": metadata
        ]
      default:
        throw BorgVRMCPServerError.unknownTool(name)
    }
  }

  private var toolDefinitions: [[String: Any]] {
    let vector3: [String: Any] = [
      "type": "array", "items": ["type": "number"], "minItems": 3, "maxItems": 3
    ]
    let vector4: [String: Any] = [
      "type": "array", "items": ["type": "number"], "minItems": 4, "maxItems": 4
    ]
    return [
      tool(
        "list_datasets",
        "List available datasets with their complete volume metadata and known sources."
      ),
      tool(
        "open_dataset",
        "Open a dataset from the catalog by its stable ID.",
        properties: ["id": ["type": "string"]],
        required: ["id"]
      ),
      tool("close_dataset", "Close the current dataset and return to dataset selection."),
      tool("get_application_state", "Return the active dataset and visualization state."),
      tool("set_render_mode", "Select transfer-function, lit transfer-function, or isovalue rendering.", properties: [
        "mode": ["type": "string", "enum": ["transfer_function", "transfer_function_lighting", "isovalue"]]
      ], required: ["mode"]),
      tool("set_transform", "Set any subset of the current model/view transform.", properties: [
        "rotation": vector4, "translation": vector3, "scale": vector3
      ]),
      tool("rotate_view", "Rotate the current model/view by an axis-angle delta.", properties: [
        "axis": vector3, "degrees": ["type": "number"]
      ], required: ["axis", "degrees"]),
      tool("set_iso_value", "Set the normalized isovalue in the range zero to one.", properties: [
        "value": ["type": "number", "minimum": 0, "maximum": 1]
      ], required: ["value"]),
      tool("set_clipping", "Set normalized minimum and maximum clipping bounds.", properties: [
        "minimum": vector3, "maximum": vector3
      ], required: ["minimum", "maximum"]),
      tool("set_lighting", "Set any subset of light direction and RGB light colors.", properties: [
        "direction": vector3, "ambient": vector3, "diffuse": vector3, "specular": vector3
      ]),
      tool(
        "set_annotation_visibility",
        "Show or hide object annotations (markers, strokes, and placed meshes) or the complete measurement visualization (points, lines, surfaces, and labels) without deleting them.",
        properties: [
          "objects": ["type": "boolean"],
          "measurements": ["type": "boolean"]
        ]
      ),
      tool("reset_state", "Reset a visualization state group.", properties: [
        "scope": ["type": "string", "enum": BorgVRMCPResetScope.allCases.map(\.rawValue)]
      ]),
      tool("wait_until_rendered", "Wait for a frame newer than the supplied frame number.", properties: [
        "after_frame": ["type": "integer", "minimum": 0],
        "timeout_seconds": ["type": "number", "minimum": 0.1, "maximum": 120]
      ]),
      tool("capture_screenshot", "Capture the current rendered view as a PNG image.")
    ]
  }

  private func tool(
    _ name: String,
    _ description: String,
    properties: [String: Any] = [:],
    required: [String] = []
  ) -> [String: Any] {
    var schema: [String: Any] = [
      "type": "object",
      "properties": properties,
      "additionalProperties": false
    ]
    if !required.isEmpty { schema["required"] = required }
    return ["name": name, "description": description, "inputSchema": schema]
  }

  private func structuredToolResult<T: Encodable>(_ value: T) -> [String: Any] {
    let data = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
    let object = (try? JSONSerialization.jsonObject(with: data)) ?? [:]
    let textData = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? data
    return [
      "content": [["type": "text", "text": String(data: textData, encoding: .utf8) ?? "{}"]],
      "structuredContent": object
    ]
  }

  private func string(_ key: String, in arguments: [String: Any]) throws -> String {
    guard let value = arguments[key] as? String else {
      throw BorgVRMCPCommandError.invalidArgument("Missing string argument '\(key)'.")
    }
    return value
  }

  private func float(_ key: String, in arguments: [String: Any]) throws -> Float {
    guard let value = arguments[key] as? NSNumber else {
      throw BorgVRMCPCommandError.invalidArgument("Missing numeric argument '\(key)'.")
    }
    let result = value.floatValue
    guard result.isFinite else {
      throw BorgVRMCPCommandError.invalidArgument("Argument '\(key)' must be finite.")
    }
    return result
  }

  private func optionalBool(_ key: String, in arguments: [String: Any]) throws -> Bool? {
    guard let rawValue = arguments[key] else { return nil }
    guard let value = rawValue as? Bool else {
      throw BorgVRMCPCommandError.invalidArgument("Argument '\(key)' must be a boolean.")
    }
    return value
  }

  private func vector3(_ key: String, in arguments: [String: Any]) throws -> SIMD3<Float> {
    guard let value = try optionalVector3(key, in: arguments) else {
      throw BorgVRMCPCommandError.invalidArgument("Missing three-component argument '\(key)'.")
    }
    return value
  }

  private func optionalVector3(_ key: String, in arguments: [String: Any]) throws -> SIMD3<Float>? {
    guard let array = arguments[key] as? [NSNumber] else { return nil }
    guard array.count == 3 else {
      throw BorgVRMCPCommandError.invalidArgument("Argument '\(key)' must contain three numbers.")
    }
    let value = SIMD3<Float>(array[0].floatValue, array[1].floatValue, array[2].floatValue)
    guard value.x.isFinite, value.y.isFinite, value.z.isFinite else {
      throw BorgVRMCPCommandError.invalidArgument("Argument '\(key)' must be finite.")
    }
    return value
  }

  private func optionalVector4(_ key: String, in arguments: [String: Any]) throws -> SIMD4<Float>? {
    guard let array = arguments[key] as? [NSNumber] else { return nil }
    guard array.count == 4 else {
      throw BorgVRMCPCommandError.invalidArgument("Argument '\(key)' must contain four numbers.")
    }
    let value = SIMD4<Float>(array[0].floatValue, array[1].floatValue, array[2].floatValue, array[3].floatValue)
    guard value.x.isFinite, value.y.isFinite, value.z.isFinite, value.w.isFinite else {
      throw BorgVRMCPCommandError.invalidArgument("Argument '\(key)' must be finite.")
    }
    return value
  }

  private func originIsAllowed(_ origin: String?) -> Bool {
    guard let origin, !origin.isEmpty else { return true }
    guard let url = URL(string: origin), let host = url.host?.lowercased() else { return false }
    if configuration.allowRemoteConnections { return true }
    return host == "localhost" || host == "127.0.0.1" || host == "::1"
  }

  private func isAuthorized(_ authorization: String?) -> Bool {
    guard configuration.allowRemoteConnections else {
      return true
    }
    authenticationLock.lock()
    let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
    authenticationLock.unlock()
    guard !token.isEmpty else { return false }
    return authorization == "Bearer \(token)"
  }

  private func validateModernHeaders(
    _ headers: [String: String],
    method: String,
    parameters: [String: Any]?
  ) -> String? {
    guard headers["mcp-protocol-version"] == Self.protocolVersion else {
      return "Missing or inconsistent MCP-Protocol-Version header."
    }
    guard headers["mcp-method"] == method else {
      return "Missing or inconsistent Mcp-Method header."
    }
    let bodyName = parameters?["name"] as? String
    if let bodyName {
      guard headers["mcp-name"] == bodyName else {
        return "Missing or inconsistent Mcp-Name header."
      }
    } else if headers["mcp-name"] != nil {
      return "Unexpected Mcp-Name header."
    }
    if let meta = parameters?["_meta"] as? [String: Any],
       let metaVersion = meta["io.modelcontextprotocol/protocolVersion"] as? String,
       metaVersion != Self.protocolVersion {
      return "Protocol version metadata does not match the HTTP header."
    }
    return nil
  }

  private func modernResult(_ value: Any) -> Any {
    guard var result = value as? [String: Any] else { return value }
    result["resultType"] = result["resultType"] ?? "complete"
    var metadata = result["_meta"] as? [String: Any] ?? [:]
    metadata["io.modelcontextprotocol/serverInfo"] = [
      "name": "BorgVR",
      "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    ]
    result["_meta"] = metadata
    return result
  }

  private func errorResponse(
    id: Any?,
    code: Int,
    message: String,
    data: Any? = nil
  ) -> [String: Any] {
    var error: [String: Any] = ["code": code, "message": message]
    if let data { error["data"] = data }
    return [
      "jsonrpc": "2.0",
      "id": id ?? NSNull(),
      "error": error
    ]
  }

  private func sendJSON(
    _ object: [String: Any],
    status: Int = 200,
    connection: NWConnection
  ) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else {
      sendHTTP(status: 500, body: Data(), connection: connection)
      return
    }
    sendHTTP(
      status: status,
      body: data,
      extraHeaders: [
        "Content-Type": "application/json",
        "MCP-Protocol-Version": Self.protocolVersion
      ],
      connection: connection
    )
  }

  private func sendHTTP(
    status: Int,
    body: Data,
    extraHeaders: [String: String] = [:],
    connection: NWConnection
  ) {
    let reason: String = switch status {
      case 200: "OK"
      case 202: "Accepted"
      case 400: "Bad Request"
      case 401: "Unauthorized"
      case 403: "Forbidden"
      case 404: "Not Found"
      case 405: "Method Not Allowed"
      case 413: "Content Too Large"
      default: "Internal Server Error"
    }
    var headers = [
      "Content-Length": "\(body.count)",
      "Connection": "close",
      "Cache-Control": "no-store"
    ]
    extraHeaders.forEach { headers[$0.key] = $0.value }
    var text = "HTTP/1.1 \(status) \(reason)\r\n"
    for key in headers.keys.sorted() {
      text += "\(key): \(headers[key] ?? "")\r\n"
    }
    text += "\r\n"
    var response = Data(text.utf8)
    response.append(body)
    connection.send(content: response, completion: .contentProcessed { [weak self] _ in
      connection.cancel()
      self?.remove(connection)
    })
  }

  private func remove(_ connection: NWConnection) {
    withConnectionLock {
      connections.removeAll { $0 === connection }
    }
  }

  @discardableResult
  private func withConnectionLock<T>(_ body: () -> T) -> T {
    connectionLock.lock()
    defer { connectionLock.unlock() }
    return body()
  }
}

private struct MCPHTTPRequest {
  let method: String
  let path: String
  let headers: [String: String]
  let body: Data
  let totalByteCount: Int

  static func parse(_ data: Data) -> MCPHTTPRequest? {
    let delimiter = Data("\r\n\r\n".utf8)
    guard let range = data.range(of: delimiter),
          let headerText = String(data: data[..<range.lowerBound], encoding: .utf8) else {
      return nil
    }
    let lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }
    let requestParts = requestLine.split(separator: " ")
    guard requestParts.count >= 2 else { return nil }

    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      headers[key] = value
    }
    let contentLength = Int(headers["content-length"] ?? "0") ?? 0
    let bodyStart = range.upperBound
    let total = bodyStart + contentLength
    guard data.count >= total else {
      return MCPHTTPRequest(
        method: String(requestParts[0]),
        path: String(requestParts[1]),
        headers: headers,
        body: Data(),
        totalByteCount: total
      )
    }
    return MCPHTTPRequest(
      method: String(requestParts[0]),
      path: String(requestParts[1]),
      headers: headers,
      body: data.subdata(in: bodyStart..<total),
      totalByteCount: total
    )
  }
}

private enum BorgVRMCPServerError: LocalizedError {
  case localhostBindingFailed
  case remoteAccessRequiresToken
  case tlsIdentityCreationFailed
  case methodNotFound(String)
  case unknownTool(String)

  var errorDescription: String? {
    switch self {
      case .localhostBindingFailed:
        return "The MCP server could not bind to localhost."
      case .remoteAccessRequiresToken:
        return "Remote MCP connections require an access token."
      case .tlsIdentityCreationFailed:
        return "Could not create the MCP HTTPS identity."
      case .methodNotFound:
        return "MCP method not found."
      case .unknownTool:
        return "Unknown BorgVR MCP tool."
    }
  }
}
