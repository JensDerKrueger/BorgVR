import Foundation
import Network
import Darwin

private struct TestFailure: Error { let message: String }

private func expect(_ condition: Bool, _ message: String) throws {
  guard condition else { throw TestFailure(message: message) }
}

private func eventually(_ message: String, _ predicate: () -> Bool) throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while ContinuousClock.now < deadline {
    if predicate() { return }
    Thread.sleep(forTimeInterval: 0.005)
  }
  throw TestFailure(message: message)
}

private func startServer(datasets: [DatasetInfo] = [], secret: String? = nil) throws -> TCPServer {
  let server = TCPServer(port: UInt16.random(in: 49152...65535), maxBricksPerGetRequest: 64,
    datasets: datasets, authSecret: secret)
  server.start()
  do {
    try eventually("Test listener did not become ready") {
      server.queue.sync { if case .ready = server.listener?.state { return true }; return false }
    }
    return server
  } catch { server.stop(); throw error }
}

private func activeCount(_ server: TCPServer) -> Int { server.queue.sync { server.activeConnections.count } }

private func connectSocket(_ server: TCPServer) throws -> Int32 {
  let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
  guard fd >= 0 else { throw POSIXError(.EIO) }
  var address = sockaddr_in()
  address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  address.sin_family = sa_family_t(AF_INET)
  address.sin_port = server.port.rawValue.bigEndian
  address.sin_addr.s_addr = inet_addr("127.0.0.1")
  let result = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  if result != 0 { Darwin.close(fd); throw POSIXError(.ECONNREFUSED) }
  try eventually("Test connection was not registered") { activeCount(server) == 1 }
  return fd
}

private func send(_ bytes: [UInt8], to fd: Int32) throws {
  var noSignal: Int32 = 1
  _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
  try bytes.withUnsafeBytes { buffer in
    var sent = 0
    while sent < buffer.count {
      let count = Darwin.send(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent, 0)
      guard count > 0 else { throw POSIXError(.EIO) }
      sent += count
    }
  }
}

private func testDisconnects() throws {
  let server = try startServer()
  defer { server.stop() }
  // Exceed the simultaneous-connection limit over time: completed clients must
  // release their slots even when their final receive contains no command bytes.
  for _ in 0..<140 {
    let fd = try connectSocket(server)
    _ = Darwin.shutdown(fd, SHUT_WR)
    _ = Darwin.close(fd)
    try eventually("Orderly disconnect retained its connection slot") { activeCount(server) == 0 }
  }
  for command in ["INVALID\n", String(repeating: "x", count: 8193) + "\n",
                  String(repeating: "x", count: 32769)] {
    let fd = try connectSocket(server)
    defer { Darwin.close(fd) }
    try send(Array(command.utf8), to: fd)
    try eventually("Rejected command retained its connection slot") { activeCount(server) == 0 }
  }
  let resetSocket = try connectSocket(server)
  var reset = linger(l_onoff: 1, l_linger: 0)
  _ = setsockopt(resetSocket, SOL_SOCKET, SO_LINGER, &reset, socklen_t(MemoryLayout<linger>.size))
  Darwin.close(resetSocket)
  try eventually("Reset connection retained its slot") { activeCount(server) == 0 }
  let stoppedSocket = try connectSocket(server)
  defer { Darwin.close(stoppedSocket) }
  server.stop()
  try expect(activeCount(server) == 0, "Server shutdown retained active clients")
}

private func testAuthenticatedDatasetSwitch() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-server-lifecycle-\(UUID())")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let metadata = BORGVRMetaData(width: 1, height: 1, depth: 1, componentCount: 1,
    bytePerComponent: 1, voxelSpacingX: 1, voxelSpacingY: 1, voxelSpacingZ: 1,
    brickSize: 1, overlap: 0, minValue: 42, maxValue: 42, compression: false,
    datasetDescription: "Lifecycle test", metaDescription: "")
  metadata.append(offset: 8, size: 1, minValue: 42, maxValue: 42)
  var file = Data(from: UInt64(9)); file.append(42); file.append(metadata.toData())
  let url = directory.appendingPathComponent("source.data")
  try file.write(to: url)
  let server = try startServer(datasets: [.init(id: metadata.uniqueID, filename: url.path, datasetDescription: "Lifecycle test")],
    secret: "review-test-password")
  defer { server.stop() }
  let client = NWConnection(host: "127.0.0.1", port: server.port, using: .tcp)
  client.start(queue: DispatchQueue(label: "BorgVR.TestClient"))
  defer { client.cancel() }
  try eventually("Authenticated client did not connect") { if case .ready = client.state { return true }; return false }
  try BorgVRServerAuthentication.authenticate(connection: client, secret: "review-test-password")
  for _ in 0..<2 {
    try BorgVRServerAuthentication.sendCommand("OPEN \(metadata.uniqueID)", connection: client)
    let response = try BorgVRBinaryFrameReceiver.receive(connection: client, timeout: 5, maximumPayloadSize: 1024 * 1024)
    let received = try BORGVRMetaData(fromData: response)
    try expect(received.uniqueID == metadata.uniqueID, "OPEN returned the wrong dataset")
  }
  try BorgVRServerAuthentication.sendCommand("GETBRICKS 0", connection: client)
  let brick = try BorgVRBinaryFrameReceiver.receive(connection: client, timeout: 5, maximumPayloadSize: 1)
  try expect(brick == Data([42]), "Dataset switch invalidated the authenticated connection")
  client.cancel()
  try eventually("Authenticated disconnect retained a connection slot") { activeCount(server) == 0 }
}

@main
private enum TCPServerLifecycleTests {
  static func main() throws {
    try testListenerReadiness()
    try testDisconnects()
    try testAuthenticatedDatasetSwitch()
    print("TCP server lifecycle and authenticated dataset-switch tests passed.")
  }
}

private func testListenerReadiness() throws {
  let first = try startServer()
  defer { first.stop() }
  let duplicate = TCPServer(port: first.port.rawValue, maxBricksPerGetRequest: 64, datasets: [])
  duplicate.start()
  defer { duplicate.stop() }
  try expect(!duplicate.isRunning, "Listener reported success before readiness")
  try eventually("Occupied-port startup did not report failure") { duplicate.lastError != nil }
  try expect(!duplicate.isRunning, "Failed listener reported itself as running")
  first.stop()
  try expect(!first.isRunning, "Stopped listener remained running")
  // A stale ready callback must not revive a stopped generation.
  let state = BorgVRListenerState()
  let generation = state.begin()
  state.stop()
  try expect(!state.finish(generation, running: true), "Stale listener callback was accepted")
}
