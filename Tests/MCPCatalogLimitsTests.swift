import Foundation
@testable import BorgVR

@main
struct MCPCatalogLimitsTests {
  @MainActor
  static func main() async throws {
    var chunks = [Data("abc\n".utf8), Data([10])]
    let text = try BorgVRTextResponse.receive(timeout: 5, maximumBytes: 5) { allowance, _ in
      let chunk = chunks.removeFirst()
      precondition(chunk.count <= allowance)
      return chunk
    }
    precondition(text == "abc\n", "Terminator split across chunks was not recognized")
    try rejectsText(.tooLarge) {
      _ = try BorgVRTextResponse.receive(timeout: 5, maximumBytes: 4) { _, _ in Data("abcd".utf8) }
    }
    try rejectsText(.incomplete) {
      _ = try BorgVRTextResponse.receive(timeout: 5, maximumBytes: 16) { _, _ in Data() }
    }
    try rejectsText(.invalidEncoding) {
      _ = try BorgVRTextResponse.receive(timeout: 5, maximumBytes: 16) { _, _ in Data([255, 10, 10]) }
    }
    try rejectsText(.tooManyEntries) {
      _ = try BorgVRTextResponse.catalogLines("one\ntwo\nthree\n", maximumEntries: 2)
    }
    let lines = try BorgVRTextResponse.catalogLines("one\ntwo\n", maximumEntries: 2)
    precondition(lines.count == 2)
    var now = 0.0
    var remainingTimes: [Double] = []
    let timed = try BorgVRTextResponse.receive(timeout: 5, maximumBytes: 16, now: { now }) { _, remaining in
      remainingTimes.append(remaining)
      now += 2
      return remainingTimes.count == 1 ? Data("x".utf8) : Data([10, 10])
    }
    precondition(timed == "x\n" && remainingTimes == [5, 3], "Receive timeout was reset between chunks")
    now = 0
    do {
      _ = try BorgVRTextResponse.receive(timeout: 5, maximumBytes: 16, now: { now }) { _, _ in
        now = 5
        return Data([10, 10])
      }
      preconditionFailure("Late response bypassed its deadline")
    } catch BORGVRRemoteDataManagerError.timeout {}

    let budget = BorgVRMCPCatalogBudget()
    defer { budget.finish() }
    var records: [String: BorgVRMCPDatasetRecord] = [:]
    func record(_ id: String, description: String = "test") -> BorgVRMCPDatasetRecord {
      .init(catalogEntry: .init(id: id, description: description, metadata: nil, metadataError: nil, sources: []),
        preferredLocation: .local(URL(fileURLWithPath: "/unused.data")))
    }
    for index in 0..<BorgVRMCPCatalogBudget.maximumEntries { try budget.store(record(String(index)), in: &records) }
    try budget.store(record("0", description: "replacement"), in: &records)
    precondition(records.count == BorgVRMCPCatalogBudget.maximumEntries)
    do {
      try budget.store(record("extra"), in: &records)
      preconditionFailure("Catalog entry limit was bypassed")
    } catch BorgVRMCPCatalogError.tooManyEntries {}
    do {
      try budget.store(record("0", description: String(repeating: "x", count: 16 * 1024 * 1024)), in: &records)
      preconditionFailure("Catalog byte limit was bypassed")
    } catch BorgVRMCPCatalogError.tooLarge {}
    precondition(records["0"]?.catalogEntry.description == "replacement", "Rejected replacement changed the catalog")
    let notified = RemoteRequestCancellation()
    let registration = budget.onCancellation { _ in notified.cancel() }
    budget.cancel()
    precondition(notified.isCancelled)
    budget.removeCancellation(registration)
    do { try budget.check(); preconditionFailure("Cancellation was ignored") }
    catch is CancellationError {}

    let cancelled = Task { try await BorgVRMCPDatasetCatalog.load(localDirectory: nil, servers: [], timeout: 5) }
    cancelled.cancel()
    do { _ = try await cancelled.value; preconditionFailure("An already cancelled catalog query succeeded") }
    catch is CancellationError {}
    print("MCP catalog byte/entry budgets, text framing, deadlines and cancellation tests passed")
  }

  private static func rejectsText(_ expected: BorgVRTextResponseError, _ action: () throws -> Void) throws {
    do { try action(); preconditionFailure("Invalid server text response was accepted") }
    catch let error as BorgVRTextResponseError {
      precondition(error == expected)
    }
  }
}
