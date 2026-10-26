import Foundation
import Network

private struct TestFailure: Error { let message: String }

private func expect(_ condition: Bool, _ message: String) throws {
  if !condition { throw TestFailure(message: message) }
}

private final class StallingServer: @unchecked Sendable {
  let requests: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation
  private let listener: NWListener
  private let queue = DispatchQueue(label: "BorgVR.StallingTestServer")
  private var connections: [NWConnection] = []
  private var readyContinuation: CheckedContinuation<Void, Error>?

  init() throws {
    (requests, continuation) = AsyncStream<Void>.makeStream()
    listener = try NWListener(using: .tcp, on: .any)
  }

  func start() async throws -> DatasetOrigin {
    try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
      readyContinuation = ready
      listener.stateUpdateHandler = { [self] state in
        guard let ready = readyContinuation else { return }
        switch state {
        case .ready:
          readyContinuation = nil
          ready.resume()
        case .failed(let error):
          readyContinuation = nil
          ready.resume(throwing: error)
        default: break
        }
      }
      listener.newConnectionHandler = { [self] connection in
        connections.append(connection)
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
          [self] data, _, _, _ in
          if data?.isEmpty == false { continuation.yield(()) }
        }
      }
      listener.start(queue: queue)
    }
    return .init(address: "127.0.0.1", port: Int(listener.port!.rawValue), password: "")
  }

  func stop() {
    listener.cancel()
    queue.sync {
      connections.forEach { $0.cancel() }
      connections.removeAll()
    }
    continuation.finish()
  }
}

@main
private enum RemoteDatasetDownloadTests {
  @MainActor
  static func main() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "borgvr-download-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let metadata = BORGVRMetaData(
      width: 1, height: 1, depth: 1, componentCount: 1,
      bytePerComponent: 1, voxelSpacingX: 1, voxelSpacingY: 1, voxelSpacingZ: 1,
      brickSize: 1, overlap: 0, minValue: 42, maxValue: 42, compression: false,
      datasetDescription: "Download test", metaDescription: "")
    metadata.append(offset: 8, size: 1, minValue: 42, maxValue: 42)
    var bytes = Data(from: UInt64(9))
    bytes.append(42)
    bytes.append(metadata.toData())
    let source = directory.appendingPathComponent("source.data")
    try bytes.write(to: source)
    let authToken = BorgVRServerAuthentication.randomToken()
    let server = TCPServer(
      port: UInt16.random(in: 49152...65535), maxBricksPerGetRequest: 64,
      datasets: [.init(id: metadata.uniqueID, filename: source.path, datasetDescription: "Test")],
      authSecret: authToken)
    server.start()
    defer { server.stop() }
    let ready = await server.waitUntilReady()
    try expect(ready, "Download test server did not start")
    let origin = DatasetOrigin(address: "127.0.0.1", port: Int(server.port.rawValue), password: authToken)
    let resolvedOrigin = await BorgVRRemoteOriginResolver.firstReachable(
      [origin], datasetID: metadata.uniqueID, timeout: 5, logger: nil,
      checking: { _ in }, receivedCatalog: { _, _ in })
    try expect(resolvedOrigin == origin, "Authenticated ad-hoc source could not be resolved")
    let invalidOrigin = DatasetOrigin(address: origin.address, port: origin.port, password: "wrong")
    let rejectedOrigin = await BorgVRRemoteOriginResolver.firstReachable(
      [invalidOrigin], datasetID: metadata.uniqueID, timeout: 5, logger: nil,
      checking: { _ in }, receivedCatalog: { _, _ in })
    try expect(rejectedOrigin == nil, "Ad-hoc server accepted an invalid password")
    let streamed = try await Task.detached {
      let manager = BORGVRRemoteDataManager(host: origin.address, port: UInt16(origin.port),
        authSecret: origin.password, logger: nil)
      try manager.connect(timeout: 5)
      return try manager.openDataset(datasetID: metadata.uniqueID, timeout: 5)
    }.value
    try expect(streamed.localRatio < 1, "A non-caching source was reported as fully local")
    streamed.stop()
    let target = directory.appendingPathComponent("download.data")
    let downloaded = try await RemoteDatasetDownloader.download(
      datasetID: metadata.uniqueID,
      origin: origin, to: target, timeout: 5, cancellation: .init(), originProvider: { [origin] },
      progress: { _ in })
    try expect(
      downloaded == target && !FileManager.default.fileExists(atPath: target.path + ".incomplete"),
      "Downloader returned before cache finalization")
    let completed = try BORGVRFileData(filename: downloaded.path)
    let buffer = completed.allocateBrickBuffer()
    defer { buffer.deallocate() }
    try completed.getBrick(index: 0, outputBuffer: buffer)
    try expect(
      buffer[0] == 42 && completed.getMetadata().uniqueID == metadata.uniqueID,
      "Finalized download contains invalid data")
    let cached = try await Task.detached {
      let manager = BORGVRRemoteDataManager(host: origin.address, port: UInt16(origin.port),
        authSecret: origin.password, logger: nil)
      try manager.connect(timeout: 5)
      return try manager.openDataset(datasetID: metadata.uniqueID, timeout: 5, localCacheFilename: target.path)
    }.value
    try expect(cached.localRatio == 1, "An existing complete cache was reported as streaming")
    cached.stop()

    let stalled = try StallingServer()
    let stalledOrigin = try await stalled.start()
    defer { stalled.stop() }
    let cancellation = RemoteRequestCancellation()
    let download = Task {
      try await RemoteDatasetDownloader.download(
        datasetID: metadata.uniqueID, origin: stalledOrigin,
        to: directory.appendingPathComponent("cancelled.data"), timeout: 30,
        cancellation: cancellation, originProvider: { [stalledOrigin] }, progress: { _ in })
    }
    var requests = stalled.requests.makeAsyncIterator()
    _ = await requests.next()
    let cancelledAt = ContinuousClock.now
    cancellation.cancel()
    do {
      _ = try await download.value
      throw TestFailure(message: "Cancelled download succeeded")
    } catch is CancellationError {}
    try expect(
      cancelledAt.duration(to: .now) < .seconds(2), "Cancellation waited for the network timeout")

    var attempts = 0
    let resolve = Task { @MainActor in
      await BorgVRRemoteOriginResolver.firstReachable(
        [stalledOrigin, origin], datasetID: metadata.uniqueID,
        timeout: 30, logger: nil, checking: { _ in attempts += 1 }, receivedCatalog: { _, _ in })
    }
    _ = await requests.next()
    let resolverCancelledAt = ContinuousClock.now
    resolve.cancel()
    let resolved = await resolve.value
    try expect(resolved == nil && attempts == 1, "Cancelled resolver queried another origin")
    try expect(
      resolverCancelledAt.duration(to: .now) < .seconds(2),
      "Resolver cancellation waited for timeout")
    print("Remote download finalization and active-network cancellation tests passed")
  }
}
