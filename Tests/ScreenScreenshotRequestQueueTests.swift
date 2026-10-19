import Foundation

private enum TestFailure: Error, CustomStringConvertible {
  case failed(String)

  var description: String {
    switch self {
      case .failed(let message): return message
    }
  }
}

private enum ScreenshotFailure: Error {
  case cancelled
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  guard condition() else { throw TestFailure.failed(message) }
}

@MainActor
private func request(id: UUID = UUID()) -> ScreenScreenshotRequest {
  ScreenScreenshotRequest(
    id: id,
    url: FileManager.default.temporaryDirectory.appendingPathComponent(id.uuidString),
    accessURL: nil,
    completion: { _ in }
  )
}

@MainActor
private func testCancelledReadbackCannotCompleteAReplacementRequest() throws {
  let queue = ScreenScreenshotRequestQueue()
  let first = request()
  try expect(queue.enqueue(first), "The first screenshot request was rejected")
  try expect(queue.takePending()?.id == first.id, "The first request did not enter flight")
  try expect(queue.cancel(id: first.id)?.id == first.id, "The in-flight request was not cancelled")

  let replacement = request()
  try expect(queue.enqueue(replacement), "A replacement request was blocked after cancellation")
  try expect(queue.takePending()?.id == replacement.id, "The replacement did not enter flight")
  try expect(
    queue.complete(id: first.id) == nil,
    "A late completion reclaimed the cancelled request"
  )
  try expect(
    queue.complete(id: replacement.id)?.id == replacement.id,
    "The replacement request could not complete"
  )
  try expect(!queue.hasOutstandingRequest, "A completed request remained in the queue")
}

@MainActor
private func testPendingCancellationAndCancelAll() throws {
  let queue = ScreenScreenshotRequestQueue()
  let pending = request()
  try expect(queue.enqueue(pending), "A pending request was rejected")
  try expect(queue.cancel(id: pending.id)?.id == pending.id, "The pending request was not cancelled")
  try expect(queue.takePending() == nil, "A cancelled pending request was still rendered")

  let inFlight = request()
  try expect(queue.enqueue(inFlight), "The in-flight test request was rejected")
  _ = queue.takePending()
  let cancelled = queue.cancelAll()
  try expect(cancelled.map(\.id) == [inFlight.id], "Cancel-all did not return the in-flight request")
  try expect(!queue.hasOutstandingRequest, "Cancel-all left a request behind")
}

@main
@MainActor
private enum ScreenScreenshotRequestQueueTestRunner {
  static func main() throws {
    try testCancelledReadbackCannotCompleteAReplacementRequest()
    try testPendingCancellationAndCancelAll()
    print("Screen screenshot request queue tests passed")
  }
}
