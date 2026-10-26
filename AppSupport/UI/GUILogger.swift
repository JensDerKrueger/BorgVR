import SwiftUI

struct BoundedLogBuffer {
  private var entries: [String?]
  private var head = 0
  private(set) var count = 0
  private(set) var byteCount = 0
  private let maximumBytes: Int
  init(maximumEntries: Int = 4000, maximumBytes: Int = 2 * 1024 * 1024) {
    entries = .init(repeating: nil, count: max(1, maximumEntries))
    self.maximumBytes = max(64, maximumBytes)
  }
  mutating func append(_ message: String) {
    var entry = message + "\n"
    if entry.utf8.count > maximumBytes {
      entry =
        String(decoding: entry.utf8.prefix(maximumBytes - 32), as: UTF8.self)
        + "\n[message truncated]\n"
    }
    let bytes = entry.utf8.count
    while count > 0 && (count == entries.count || byteCount + bytes > maximumBytes) {
      byteCount -= entries[head]!.utf8.count
      entries[head] = nil
      head = (head + 1) % entries.count
      count -= 1
    }
    entries[(head + count) % entries.count] = entry
    byteCount += bytes
    count += 1
  }
  mutating func removeAll() {
    entries = .init(repeating: nil, count: entries.count)
    head = 0
    count = 0
    byteCount = 0
  }
  var text: String { (0..<count).map { entries[(head + $0) % entries.count]! }.joined() }
}

/// A logger that retains messages and publishes them to optional SwiftUI bindings.
public final class GUILogger: LoggerBase, @unchecked Sendable {
  private var logBinding: Binding<String>?
  private let lock = NSLock()
  private var buffer = BoundedLogBuffer()
  private var publicationScheduled = false
  private var progressTextBinding: Binding<String>?
  private var progressBinding: Binding<Double>?
  private let filter = LogLevelFilter()

  public init() {}

  public func setLogBinding(_ newLog: Binding<String>) {
    DispatchQueue.main.async {
      self.logBinding = newLog
      self.publishLog()
    }
  }

  public func clear() {
    lock.withLock { buffer.removeAll() }
    schedulePublication()
  }

  public func setProgressBinding(_ newText: Binding<String>, _ newProgress: Binding<Double>) {
    DispatchQueue.main.async {
      self.progressTextBinding = newText
      self.progressBinding = newProgress
    }
  }

  public func dev(_ message: String) {
    appendLog(message, level: .dev)
  }

  public func info(_ message: String) {
    appendLog(message, level: .info)
  }

  public func warning(_ message: String) {
    appendLog(
      "[\(localizedLogLevel("log_level_warning", fallback: "WARNING"))] \(message)",
      level: .warning
    )
  }

  public func error(_ message: String) {
    appendLog(
      "[\(localizedLogLevel("log_level_error", fallback: "ERROR"))] \(message)",
      level: .error
    )
  }

  public func progress(_ message: String, _ progress: Double) {
    guard filter.allows(.progress) else { return }
    let progress = min(max(progress, 0), 1)
    DispatchQueue.main.async {
      self.progressTextBinding?.wrappedValue = message
      self.progressBinding?.wrappedValue = progress
    }
  }

  public func setMinimumLogLevel(_ level: LogLevel) {
    filter.setMinimumLevel(level)
  }

  private func appendLog(_ message: String, level: LogLevel) {
    guard filter.allows(level) else { return }
    lock.withLock { buffer.append(message) }
    schedulePublication()
  }

  private func schedulePublication() {
    let scheduled = lock.withLock {
      guard !publicationScheduled else { return false }
      publicationScheduled = true
      return true
    }
    if scheduled { DispatchQueue.main.async { self.publishLog() } }
  }

  private func publishLog() {
    let text = lock.withLock {
      publicationScheduled = false
      return buffer.text
    }
    logBinding?.wrappedValue = text
  }

  private func localizedLogLevel(_ key: String, fallback: String) -> String {
    NSLocalizedString(
      key, tableName: nil, bundle: .main, value: fallback, comment: "Log level label")
  }
}

/*
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of Duisburg-
 Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of this
 software and associated documentation files (the "Software"), to deal in the Software
 without restriction, including without limitation the rights to use, copy, modify,
 merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 permit persons to whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included in all copies
 or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
 CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR
 THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
