import CryptoKit
import Foundation
import Network
import Security

enum BorgVRServerAuthentication {
  static let protocolVersionName = BorgVRServerProtocol.authenticationMinimumVersionName
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
    let helloText = try receiveTextResponse(connection: connection, timeout: timeout, maximumBytes: 16 * 1024)
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
    let authText = try receiveTextResponse(connection: connection, timeout: timeout, maximumBytes: 16 * 1024)
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
    timeout: TimeInterval = 5,
    maximumBytes: Int = BorgVRTextResponse.maximumBytes
  ) throws -> String {
    do {
      return try BorgVRTextResponse.receive(timeout: timeout, maximumBytes: maximumBytes) { maximumLength, remaining in
        let operation = BorgVRTextReceiveOperation()
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, _, error in
          operation.finish(data: data, error: error)
        }
        return try operation.wait(timeout: remaining)
      }
    } catch {
      connection.cancel()
      throw error
    }
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

enum BorgVRTextResponseError: Error, LocalizedError, Equatable {
  case invalidLimit, tooLarge, tooManyEntries, invalidEncoding, incomplete

  var errorDescription: String? {
    switch self {
      case .invalidLimit: "Invalid text response limit."
      case .tooLarge: "Server text response exceeds the byte limit."
      case .tooManyEntries: "Server catalog exceeds the entry limit."
      case .invalidEncoding: "Server text response is not valid UTF-8."
      case .incomplete: "Server closed the connection before completing its text response."
    }
  }
}

enum BorgVRTextResponse {
  static let maximumBytes = 4 * 1024 * 1024
  static let maximumCatalogEntries = 10000

  static func catalogLines(_ response: String, maximumEntries: Int = maximumCatalogEntries) throws -> [Substring] {
    guard maximumEntries > 0, maximumEntries <= maximumCatalogEntries else { throw BorgVRTextResponseError.invalidLimit }
    guard response.utf8.count <= maximumBytes else { throw BorgVRTextResponseError.tooLarge }
    let lines = response.split(separator: "\n", maxSplits: maximumEntries, omittingEmptySubsequences: true)
    guard lines.count <= maximumEntries else { throw BorgVRTextResponseError.tooManyEntries }
    return lines
  }

  static func receive(timeout: TimeInterval, maximumBytes: Int,
                      now: () -> TimeInterval = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 },
                      read: (Int, TimeInterval) throws -> Data) throws -> String {
    guard timeout.isFinite, timeout > 0, maximumBytes > 0,
          maximumBytes <= Self.maximumBytes else { throw BorgVRTextResponseError.invalidLimit }
    let deadline = now() + timeout
    let delimiter = Data([10, 10])
    var buffer = Data()
    while true {
      let remaining = deadline - now()
      guard remaining > 0 else { throw BORGVRRemoteDataManagerError.timeout(seconds: timeout) }
      guard buffer.count < maximumBytes else { throw BorgVRTextResponseError.tooLarge }
      let allowance = min(4096, maximumBytes - buffer.count)
      let chunk = try read(allowance, remaining)
      guard now() < deadline else { throw BORGVRRemoteDataManagerError.timeout(seconds: timeout) }
      guard !chunk.isEmpty else { throw BorgVRTextResponseError.incomplete }
      guard chunk.count <= allowance else { throw BorgVRTextResponseError.tooLarge }
      let searchStart = max(0, buffer.count - 1)
      buffer.append(chunk)
      // Search bytes incrementally; decode only once, after finding the terminator.
      if let range = buffer.range(of: delimiter, in: searchStart..<buffer.count) {
        guard let text = String(data: buffer[..<(range.upperBound - 1)], encoding: .utf8) else {
          throw BorgVRTextResponseError.invalidEncoding
        }
        return text
      }
    }
  }
}

private final class BorgVRTextReceiveOperation: @unchecked Sendable {
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private var completed = false
  private var data: Data?
  private var error: Error?

  func finish(data: Data?, error: Error?) {
    let signal = lock.withLock {
      guard !completed else { return false }
      completed = true
      self.data = data
      self.error = error
      return true
    }
    if signal { semaphore.signal() }
  }

  func wait(timeout: TimeInterval) throws -> Data {
    guard semaphore.wait(timeout: .now() + timeout) != .timedOut else {
      lock.withLock { completed = true }
      throw BORGVRRemoteDataManagerError.timeout(seconds: timeout)
    }
    return try lock.withLock {
      if let error { throw BORGVRRemoteDataManagerError.receiveFailed(reason: error.localizedDescription) }
      return data ?? Data()
    }
  }
}
