import Foundation

struct ScreenScreenshotRequest {
  let id: UUID
  let url: URL
  let accessURL: URL?
  let completion: (Result<URL, Error>) -> Void
}

@MainActor
final class ScreenScreenshotRequestQueue {
  private var pendingRequest: ScreenScreenshotRequest?
  private var inFlightRequests: [UUID: ScreenScreenshotRequest] = [:]

  var hasOutstandingRequest: Bool {
    pendingRequest != nil || !inFlightRequests.isEmpty
  }

  func enqueue(_ request: ScreenScreenshotRequest) -> Bool {
    guard !hasOutstandingRequest else { return false }
    pendingRequest = request
    return true
  }

  func takePending() -> ScreenScreenshotRequest? {
    guard let request = pendingRequest else { return nil }
    pendingRequest = nil
    inFlightRequests[request.id] = request
    return request
  }

  func complete(id: UUID) -> ScreenScreenshotRequest? {
    inFlightRequests.removeValue(forKey: id)
  }

  func cancel(id: UUID) -> ScreenScreenshotRequest? {
    if pendingRequest?.id == id {
      defer { pendingRequest = nil }
      return pendingRequest
    }
    return inFlightRequests.removeValue(forKey: id)
  }

  func cancelAll() -> [ScreenScreenshotRequest] {
    var requests = Array(inFlightRequests.values)
    if let pendingRequest {
      requests.append(pendingRequest)
    }
    pendingRequest = nil
    inFlightRequests.removeAll()
    return requests
  }
}
