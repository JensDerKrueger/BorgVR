import Compression
import Foundation

// MARK: - Log levels

public enum LogLevel: Int, Comparable {
  case dev = 0
  case progress = 1
  case info = 2
  case warning = 3
  case error = 4

  public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

public protocol LoggerBase {
  func dev(_ message: String)
  func info(_ message: String)
  func warning(_ message: String)
  func error(_ message: String)
  func progress(_ message: String, _ progress: Double)
  func setMinimumLogLevel(_ level: LogLevel)
}

/// Thread-safe minimum-level storage shared by all logger implementations.
final class LogLevelFilter: @unchecked Sendable {
  private let lock = NSLock()
  private var minimumLevel: LogLevel

  init(minimumLevel: LogLevel = .progress) {
    self.minimumLevel = minimumLevel
  }

  func setMinimumLevel(_ level: LogLevel) {
    lock.lock()
    minimumLevel = level
    lock.unlock()
  }

  var currentLevel: LogLevel {
    lock.lock()
    defer { lock.unlock() }
    return minimumLevel
  }

  func allows(_ level: LogLevel) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return level >= minimumLevel
  }
}

enum LogMessageSanitizer {
  static func sanitize(_ message: String) -> String {
    var output = ""
    output.reserveCapacity(message.utf8.count)
    for scalar in message.unicodeScalars {
      let value = scalar.value
      if isUnsafe(value) {
        output += String(format: "\\u{%X}", value)
      } else {
        output.unicodeScalars.append(scalar)
      }
    }
    return output
  }

  private static func isUnsafe(_ value: UInt32) -> Bool {
    value < 0x20 ||
      (value >= 0x7f && value <= 0x9f) ||
      value == 0x00ad ||
      value == 0x061c ||
      (value >= 0x200b && value <= 0x200f) ||
      (value >= 0x2028 && value <= 0x202e) ||
      (value >= 0x2060 && value <= 0x206f) ||
      value == 0xfeff ||
      (value >= 0xfff9 && value <= 0xfffb)
  }
}

// MARK: - Multiplex logger

/// Serializes and forwards accepted messages to multiple destinations.
public final class MultiplexLogger: LoggerBase, @unchecked Sendable {
  private let filter: LogLevelFilter
  private let stateLock = NSLock()
  private let emissionLock = NSRecursiveLock()
  private var loggers: [LoggerBase]

  public init(loggers: [LoggerBase] = [], minimumLogLevel: LogLevel = .progress) {
    self.loggers = loggers
    filter = LogLevelFilter(minimumLevel: minimumLogLevel)
    loggers.forEach { $0.setMinimumLogLevel(.dev) }
  }

  public func setMinimumLogLevel(_ level: LogLevel) {
    filter.setMinimumLevel(level)
  }

  public var currentLevel: LogLevel {
    filter.currentLevel
  }

  public func add(logger: LoggerBase) {
    logger.setMinimumLogLevel(.dev)
    stateLock.lock()
    loggers.append(logger)
    stateLock.unlock()
  }

  public func dev(_ message: String) {
    emit(level: .dev) { $0.dev(message) }
  }

  public func progress(_ message: String, _ progress: Double) {
    emit(level: .progress) { $0.progress(message, progress) }
  }

  public func info(_ message: String) {
    emit(level: .info) { $0.info(message) }
  }

  public func warning(_ message: String) {
    emit(level: .warning) { $0.warning(message) }
  }

  public func error(_ message: String) {
    emit(level: .error) { $0.error(message) }
  }

  private func emit(level: LogLevel, action: (LoggerBase) -> Void) {
    guard filter.allows(level) else { return }

    stateLock.lock()
    let destinations = loggers
    stateLock.unlock()

    emissionLock.lock()
    destinations.forEach(action)
    emissionLock.unlock()
  }
}

// MARK: - File logger

public final class FileLogger: LoggerBase, @unchecked Sendable {
  private enum FileLoggerError: LocalizedError {
    case compressionFailed

    var errorDescription: String? {
      "The rotated log file could not be compressed."
    }
  }

  private static let standardErrorLock = NSLock()

  private let logFile: URL
  private let maxFileSize: Int
  private let flushImmediately: Bool
  private let enableCompression: Bool
  private let errorHandler: (@Sendable (String) -> Void)?
  private let filter = LogLevelFilter()
  private let fileLock = NSLock()
  private let dateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  public init(
    logFilePath: String = "/tmp/app_log.txt",
    maxFileSize: Int = 1024 * 1024,
    flushImmediately: Bool = true,
    enableCompression: Bool = false,
    errorHandler: (@Sendable (String) -> Void)? = nil
  ) {
    logFile = URL(fileURLWithPath: logFilePath)
    self.maxFileSize = maxFileSize
    self.flushImmediately = flushImmediately
    self.enableCompression = enableCompression
    self.errorHandler = errorHandler
  }

  public func setMinimumLogLevel(_ level: LogLevel) {
    filter.setMinimumLevel(level)
  }

  public func dev(_ message: String) {
    write(level: .dev, label: "DEV", message: message)
  }

  public func progress(_ message: String, _ progress: Double) {
    let progress = min(max(progress, 0), 1)
    write(
      level: .progress,
      label: "PROGRESS",
      message: "\(message) - \(Int(progress * 100))%"
    )
  }

  public func info(_ message: String) {
    write(level: .info, label: "INFO", message: message)
  }

  public func warning(_ message: String) {
    write(level: .warning, label: "WARNING", message: message)
  }

  public func error(_ message: String) {
    write(level: .error, label: "ERROR", message: message)
  }

  private func write(level: LogLevel, label: String, message: String) {
    guard filter.allows(level) else { return }

    var failure: Error?
    fileLock.lock()
    do {
      try rotateLogIfNeeded()
      try append("\(dateFormatter.string(from: Date())) [\(label)] \(message)\n")
    } catch {
      failure = error
    }
    fileLock.unlock()

    if let failure {
      reportFailure("Could not write log file \(logFile.path): \(failure.localizedDescription)")
    }
  }

  private func append(_ message: String) throws {
    if !FileManager.default.fileExists(atPath: logFile.path) {
      try Data().write(to: logFile, options: .atomic)
    }
    let fileHandle = try FileHandle(forWritingTo: logFile)
    defer { try? fileHandle.close() }
    try fileHandle.seekToEnd()
    try fileHandle.write(contentsOf: Data(message.utf8))
    if flushImmediately {
      try fileHandle.synchronize()
    }
  }

  private func rotateLogIfNeeded() throws {
    guard FileManager.default.fileExists(atPath: logFile.path) else { return }
    let attributes = try FileManager.default.attributesOfItem(atPath: logFile.path)
    let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
    guard fileSize >= maxFileSize else { return }

    let archiveURL = logFile.deletingPathExtension().appendingPathExtension("old.log")
    if FileManager.default.fileExists(atPath: archiveURL.path) {
      try FileManager.default.removeItem(at: archiveURL)
    }
    try FileManager.default.moveItem(at: logFile, to: archiveURL)
    if enableCompression {
      try compressFile(at: archiveURL)
    }
  }

  private func compressFile(at fileURL: URL) throws {
    let inputData = try Data(contentsOf: fileURL)
    guard let compressedData = zlibCompress(inputData) else {
      throw FileLoggerError.compressionFailed
    }
    let compressedURL = fileURL.appendingPathExtension("zlib")
    try compressedData.write(to: compressedURL, options: .atomic)
    try FileManager.default.removeItem(at: fileURL)
  }

  private func zlibCompress(_ data: Data) -> Data? {
    guard !data.isEmpty else { return Data() }
    let scratchSize = compression_encode_scratch_buffer_size(COMPRESSION_ZLIB)
    let scratch = UnsafeMutableRawPointer.allocate(
      byteCount: max(scratchSize, 1),
      alignment: MemoryLayout<UInt8>.alignment
    )
    defer { scratch.deallocate() }

    return data.withUnsafeBytes { rawBuffer in
      guard let source = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
        return nil
      }
      var capacity = max(64, data.count + data.count / 8 + 64)
      for _ in 0..<8 {
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        let compressedSize = compression_encode_buffer(
          destination,
          capacity,
          source,
          data.count,
          scratch,
          COMPRESSION_ZLIB
        )
        if compressedSize > 0 {
          let result = Data(bytes: destination, count: compressedSize)
          destination.deallocate()
          return result
        }
        destination.deallocate()
        capacity *= 2
      }
      return nil
    }
  }

  private func reportFailure(_ message: String) {
    let message = LogMessageSanitizer.sanitize(message)
    if let errorHandler {
      errorHandler(message)
      return
    }

    Self.standardErrorLock.lock()
    defer { Self.standardErrorLock.unlock() }
    try? FileHandle.standardError.write(contentsOf: Data("[LOGGER ERROR] \(message)\n".utf8))
  }
}

// MARK: - Terminal logger

public final class PrintfLogger: LoggerBase, @unchecked Sendable {
  public enum ETAFormat {
    case mmss
    case seconds
    case hhmmss
    case rawSeconds
  }

  private let useColors: Bool
  private let etaFormat: ETAFormat
  private let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
  private let filter = LogLevelFilter()
  private let outputLock = NSLock()
  private var spinnerIndex = 0
  private var startTime: Date?

  public init(useColors: Bool = true, etaFormat: ETAFormat = .mmss) {
    self.useColors = useColors
    self.etaFormat = etaFormat
  }

  public func setMinimumLogLevel(_ level: LogLevel) {
    filter.setMinimumLevel(level)
  }

  public func dev(_ message: String) {
    write(level: .dev, message: message, color: "\u{001B}[36m", label: "DEV")
  }

  public func info(_ message: String) {
    write(level: .info, message: message, color: "\u{001B}[32m", label: "INFO")
  }

  public func warning(_ message: String) {
    write(level: .warning, message: message, color: "\u{001B}[33m", label: "WARNING")
  }

  public func error(_ message: String) {
    write(level: .error, message: message, color: "\u{001B}[31m", label: "ERROR")
  }

  public func progress(_ message: String, _ progress: Double) {
    guard filter.allows(.progress) else { return }
    let progress = min(max(progress, 0), 1)

    outputLock.lock()
    defer { outputLock.unlock() }

    let barLength = 30
    let filled = Int(progress * Double(barLength))
    let bar = "[" + String(repeating: "█", count: filled) +
      String(repeating: "-", count: barLength - filled) + "]"
    if progress > 0 && startTime == nil {
      startTime = Date()
    }
    let spinner = spinnerFrames[spinnerIndex]
    spinnerIndex = (spinnerIndex + 1) % spinnerFrames.count
    let safeMessage = LogMessageSanitizer.sanitize(message)
    let line = "\r\(spinner) \(safeMessage) \(bar) \(Int(progress * 100))% " +
      "ETA: \(calculateETA(progress))\u{001B}[K"
    print(coloredText(line, color: "\u{001B}[36m"), terminator: "")
    fflush(stdout)

    if progress >= 1 {
      print("")
      startTime = nil
    }
  }

  private func write(level: LogLevel, message: String, color: String, label: String) {
    guard filter.allows(level) else { return }
    outputLock.lock()
    defer { outputLock.unlock() }
    let safeMessage = LogMessageSanitizer.sanitize(message)
    let terminalReset = useColors ? "\u{001B}(B\u{000F}" : ""
    print(terminalReset + coloredText("[\(label)] \(safeMessage)", color: color) + terminalReset)
    fflush(stdout)
  }

  private func coloredText(_ text: String, color: String) -> String {
    useColors ? "\(color)\(text)\u{001B}[0m" : text
  }

  private func calculateETA(_ progress: Double) -> String {
    guard let startTime, progress > 0 else { return "--:--" }
    let elapsed = Date().timeIntervalSince(startTime)
    let remaining = max(0, elapsed / progress - elapsed)
    switch etaFormat {
      case .mmss:
        return String(format: "%02d:%02d", Int(remaining) / 60, Int(remaining) % 60)
      case .seconds:
        return "\(Int(remaining)) seconds"
      case .hhmmss:
        return String(
          format: "%02d:%02d:%02d",
          Int(remaining) / 3600,
          (Int(remaining) % 3600) / 60,
          Int(remaining) % 60
        )
      case .rawSeconds:
        return String(format: "%.2fs", remaining)
    }
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
