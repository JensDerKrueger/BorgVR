import Foundation

private enum TestFailure: Error, CustomStringConvertible {
  case failed(String)

  var description: String {
    switch self {
      case .failed(let message): message
    }
  }
}

private func expect(
  _ condition: @autoclosure () -> Bool,
  _ message: String
) throws {
  guard condition() else { throw TestFailure.failed(message) }
}

private final class CollectingLogger: LoggerBase, @unchecked Sendable {
  private let lock = NSLock()
  private var minimumLevel = LogLevel.dev
  private var entries: [(LogLevel, String)] = []

  var snapshot: [(LogLevel, String)] {
    lock.lock()
    defer { lock.unlock() }
    return entries
  }

  func setMinimumLogLevel(_ level: LogLevel) {
    lock.lock()
    minimumLevel = level
    lock.unlock()
  }

  func dev(_ message: String) { append(.dev, message) }
  func info(_ message: String) { append(.info, message) }
  func warning(_ message: String) { append(.warning, message) }
  func error(_ message: String) { append(.error, message) }
  func progress(_ message: String, _ progress: Double) { append(.progress, message) }

  private func append(_ level: LogLevel, _ message: String) {
    lock.lock()
    if level >= minimumLevel {
      entries.append((level, message))
    }
    lock.unlock()
  }
}

private func testFilterAndSanitizer() throws {
  let filter = LogLevelFilter(minimumLevel: .warning)
  try expect(!filter.allows(.info), "Log filter accepted a lower level")
  try expect(filter.allows(.warning), "Log filter rejected its minimum level")
  try expect(filter.allows(.error), "Log filter rejected a higher level")
  filter.setMinimumLevel(.dev)
  try expect(filter.currentLevel == .dev, "Log filter did not update")

  let sanitized = LogMessageSanitizer.sanitize("safe\u{1B}[31m\ntext\u{202E}")
  try expect(!sanitized.contains("\u{1B}"), "ANSI escape survived sanitization")
  try expect(!sanitized.contains("\n"), "Newline survived sanitization")
  try expect(sanitized.contains("\\u{1B}"), "ANSI escape was not made visible")
  try expect(sanitized.contains("\\u{202E}"), "Bidirectional override was not escaped")
}

private func testMultiplexFilteringAndConcurrency() throws {
  let first = CollectingLogger()
  let second = CollectingLogger()
  let logger = MultiplexLogger(loggers: [first], minimumLogLevel: .info)
  logger.add(logger: second)
  logger.dev("hidden")
  logger.progress("hidden", 0.5)
  logger.info("visible")

  DispatchQueue.concurrentPerform(iterations: 100) { index in
    logger.warning("warning-\(index)")
  }

  for destination in [first, second] {
    let entries = destination.snapshot
    try expect(entries.count == 101, "Multiplex logger lost or duplicated messages")
    try expect(!entries.contains { $0.1 == "hidden" }, "Multiplex filtering was bypassed")
    try expect(entries.first?.1 == "visible", "Multiplex emission order changed")
  }
}

private func testFileFilteringConcurrencyAndRotation() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("borgvr-logger-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let filteredURL = directory.appendingPathComponent("filtered.log")
  let filtered = FileLogger(logFilePath: filteredURL.path)
  filtered.setMinimumLogLevel(.warning)
  filtered.info("hidden")
  filtered.warning("visible")
  let filteredText = try String(contentsOf: filteredURL, encoding: .utf8)
  try expect(!filteredText.contains("hidden"), "File logger ignored its minimum level")
  try expect(filteredText.contains("[WARNING] visible"), "File logger lost a warning")

  let concurrentURL = directory.appendingPathComponent("concurrent.log")
  let concurrent = FileLogger(
    logFilePath: concurrentURL.path,
    maxFileSize: 10 * 1024 * 1024,
    flushImmediately: false
  )
  DispatchQueue.concurrentPerform(iterations: 200) { index in
    concurrent.info("entry-\(index)")
  }
  let lines = try String(contentsOf: concurrentURL, encoding: .utf8)
    .split(separator: "\n")
  try expect(lines.count == 200, "Concurrent file logging lost or merged lines")

  let rotatingURL = directory.appendingPathComponent("rotating.log")
  let rotating = FileLogger(
    logFilePath: rotatingURL.path,
    maxFileSize: 1,
    enableCompression: true
  )
  rotating.info(String(repeating: "A", count: 1024))
  rotating.info("new-file")
  let archiveURL = rotatingURL.deletingPathExtension()
    .appendingPathExtension("old.log")
    .appendingPathExtension("zlib")
  try expect(
    FileManager.default.fileExists(atPath: archiveURL.path),
    "Compressed log rotation did not create an archive"
  )
  let archiveData = try Data(contentsOf: archiveURL)
  try expect(
    !archiveData.isEmpty,
    "Compressed log archive is empty"
  )
  let currentText = try String(contentsOf: rotatingURL, encoding: .utf8)
  try expect(currentText.contains("new-file"), "Logging did not continue after rotation")
}

@main
private enum LoggerTestRunner {
  static func main() throws {
    try testFilterAndSanitizer()
    try testMultiplexFilteringAndConcurrency()
    try testFileFilteringConcurrencyAndRotation()
    try testBoundedGUIBuffer()
    print("Logger tests passed")
  }
}

private func testBoundedGUIBuffer() throws {
  var buffer = BoundedLogBuffer()
  for index in 0..<5000 { buffer.append("entry-\(index)") }
  let lines = buffer.text.split(separator: "\n")
  try expect(buffer.count == 4000 && lines.count == 4000, "GUI log exceeded its entry limit")
  try expect(lines.first == "entry-1000" && lines.last == "entry-4999", "GUI log lost FIFO order")
  var small = BoundedLogBuffer(maximumEntries: 100, maximumBytes: 128)
  for _ in 0..<100 { small.append("ä😀") }
  try expect(small.byteCount <= 128, "GUI log exceeded its byte limit")
  small.append(String(repeating: "😀", count: 1000))
  try expect(small.byteCount <= 128 && small.text.contains("[message truncated]"), "Oversized GUI entry was not bounded")
  small.removeAll()
  try expect(small.count == 0 && small.byteCount == 0 && small.text.isEmpty, "GUI log clear did not reset the FIFO")
}
