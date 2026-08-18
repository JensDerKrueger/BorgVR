import CryptoKit
import Foundation
import Network
import Security

enum BorgVRServerAuthentication {
  static let protocolVersionName = "2"
  static let nonceByteCount = 32
  static let saltByteCount = 16

  static func normalizedSecret(_ secret: String?) -> String {
    secret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  static func randomToken() -> String {
    randomData(byteCount: 32).base64EncodedString()
  }

  static func randomNonce() -> Data {
    randomData(byteCount: nonceByteCount)
  }

  static func randomSalt() -> Data {
    randomData(byteCount: saltByteCount)
  }

  static func response(secret: String, salt: Data, serverNonce: Data, clientNonce: Data) -> String {
    let secretData = Data(secret.utf8)
    var keySeed = Data()
    keySeed.append(secretData)
    keySeed.append(salt)
    let keyDigest = SHA256.hash(data: keySeed)
    let key = SymmetricKey(data: Data(keyDigest))
    var message = Data()
    message.append(serverNonce)
    message.append(clientNonce)
    let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)
    return Data(mac).base64EncodedString()
  }

  static func authenticate(
    connection: NWConnection,
    secret: String?,
    timeout: TimeInterval = 5,
    logger: LoggerBase? = nil
  ) throws {
    try sendCommand("HELLO", connection: connection, timeout: timeout)
    let helloText = try receiveTextResponse(connection: connection, timeout: timeout)
    let hello = KeyValuePairHandler(text: helloText)

    guard let version = hello.string(for: "VERSION") else {
      throw BORGVRRemoteDataManagerError.invalidResponse(reason: "Missing protocol version in HELLO response.")
    }
    guard serverProtocolVersion(version) >= serverProtocolVersion(protocolVersionName) else {
      throw BORGVRRemoteDataManagerError.invalidResponse(
        reason: "Unsupported server protocol version. Server: \(version) (Local: \(protocolVersionName))."
      )
    }

    let authMode = hello.string(for: "AUTH")?.uppercased() ?? "NONE"
    if authMode == "NONE" {
      return
    }
    guard authMode == "REQUIRED" else {
      throw BORGVRRemoteDataManagerError.invalidResponse(reason: "Unsupported authentication mode: \(authMode).")
    }

    let normalizedSecret = normalizedSecret(secret)
    guard !normalizedSecret.isEmpty else {
      throw BORGVRRemoteDataManagerError.invalidResponse(reason: "Server requires a password.")
    }
    guard
      let saltText = hello.string(for: "SALT"),
      let serverNonceText = hello.string(for: "SERVER_NONCE"),
      let salt = Data(base64Encoded: saltText),
      let serverNonce = Data(base64Encoded: serverNonceText)
    else {
      throw BORGVRRemoteDataManagerError.invalidResponse(reason: "Invalid authentication challenge.")
    }

    let clientNonce = randomNonce()
    let clientNonceText = clientNonce.base64EncodedString()
    let responseText = response(
      secret: normalizedSecret,
      salt: salt,
      serverNonce: serverNonce,
      clientNonce: clientNonce
    )

    try sendCommand("AUTH \(clientNonceText) \(responseText)", connection: connection, timeout: timeout)
    let authText = try receiveTextResponse(connection: connection, timeout: timeout)
    let auth = KeyValuePairHandler(text: authText)
    guard auth.string(for: "AUTH")?.uppercased() == "OK" else {
      logger?.warning("Server authentication failed.")
      throw BORGVRRemoteDataManagerError.invalidResponse(reason: "Server authentication failed.")
    }
  }

  static func sendCommand(
    _ command: String,
    connection: NWConnection,
    timeout: TimeInterval = 5
  ) throws {
    let semaphore = DispatchSemaphore(value: 0)
    var sendError: Error?

    let terminatedCommand = command.hasSuffix("\n") ? command : command + "\n"
    guard let commandData = terminatedCommand.data(using: .utf8) else {
      throw BORGVRRemoteDataManagerError.sendFailed(
        NSError(
          domain: "Encoding",
          code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Failed to encode command"]
        )
      )
    }

    connection.send(content: commandData, completion: .contentProcessed { error in
      sendError = error
      semaphore.signal()
    })

    let result = semaphore.wait(timeout: .now() + timeout)
    if result == .timedOut {
      throw BORGVRRemoteDataManagerError.timeout(seconds: timeout)
    }
    if let error = sendError {
      throw BORGVRRemoteDataManagerError.sendFailed(error)
    }
  }

  static func receiveTextResponse(
    connection: NWConnection,
    timeout: TimeInterval = 5
  ) throws -> String {
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
        throw BORGVRRemoteDataManagerError.receiveFailed(reason: error.localizedDescription)
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

  private static func randomData(byteCount: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    if status != errSecSuccess {
      fatalError("Unable to generate secure random bytes.")
    }
    return Data(bytes)
  }

  private static func serverProtocolVersion(_ version: String) -> Int {
    Int(version) ?? 0
  }
}
