import Foundation

enum CachingRemoteWaitResult {
  case available
  case stopped(lastError: Error?)
  case timedOut(lastError: Error?)
}

/** Coordinates mutable caching state and wakes synchronous first-brick waiters. */
final class CachingRemoteLifecycle {
  private enum FinalizationState {
    case pending
    case inProgress
    case complete
  }

  private let condition = NSCondition()
  private var terminated = false
  private var cachingComplete = false
  private var finalizationState = FinalizationState.pending
  private var lastFetchError: Error?

  var isTerminated: Bool {
    condition.lock()
    defer { condition.unlock() }
    return terminated
  }

  var isCachingComplete: Bool {
    condition.lock()
    defer { condition.unlock() }
    return cachingComplete
  }

  var isLocalCopyFinalized: Bool {
    condition.lock()
    defer { condition.unlock() }
    return finalizationState == .complete
  }

  @discardableResult
  func requestStop() -> Bool {
    condition.lock()
    defer { condition.unlock() }
    guard !terminated else { return false }
    terminated = true
    condition.broadcast()
    return true
  }

  func recordFetchFailure(_ error: Error) {
    condition.lock()
    lastFetchError = error
    condition.broadcast()
    condition.unlock()
  }

  func recordBrickAvailable() {
    condition.lock()
    lastFetchError = nil
    condition.broadcast()
    condition.unlock()
  }

  func markCachingComplete() {
    condition.lock()
    cachingComplete = true
    lastFetchError = nil
    condition.broadcast()
    condition.unlock()
  }

  func waitUntilAvailable(
    deadline: Date,
    isAvailable: () -> Bool
  ) -> CachingRemoteWaitResult {
    condition.lock()
    defer { condition.unlock() }

    while true {
      if isAvailable() { return .available }
      if terminated { return .stopped(lastError: lastFetchError) }
      if !condition.wait(until: deadline) {
        if isAvailable() { return .available }
        if terminated { return .stopped(lastError: lastFetchError) }
        return .timedOut(lastError: lastFetchError)
      }
    }
  }

  func beginFinalization() -> Bool {
    condition.lock()
    defer { condition.unlock() }
    guard cachingComplete, finalizationState == .pending else { return false }
    finalizationState = .inProgress
    return true
  }

  func finishFinalization(success: Bool) {
    condition.lock()
    finalizationState = success ? .complete : .pending
    condition.broadcast()
    condition.unlock()
  }
}
