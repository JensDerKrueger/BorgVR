import Foundation
import Compression
import os
import SwiftUI

// MARK: - LogLevel

/**
 Defines various log levels for filtering messages.

 The log levels are ordered by severity:
 - dev: Informational messages for developers only (least severe)
 - progress: Detailed progress updates
 - info: Informational messages
 - warning: Warnings about potential issues
 - error: Error messages (most severe)
 */
public enum LogLevel: Int, Comparable {
  /// Informational messages for developers
  case dev = 0
  /// Detailed progress updates.
  case progress = 1
  /// Informational messages.
  case info = 2
  /// Warnings about potential issues.
  case warning = 3
  /// Error messages.
  case error = 4

  /**
   Enables comparing log levels by their raw integer values.

   - Parameters:
   - lhs: The left-hand side `LogLevel`.
   - rhs: The right-hand side `LogLevel`.
   - Returns: `true` if `lhs.rawValue < rhs.rawValue`.
   */
  public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
    return lhs.rawValue < rhs.rawValue
  }
}

// MARK: - Logger Protocol

/**
 The `LoggerBase` protocol defines the core logging methods.

 Any logger conforming to `LoggerBase` must implement methods to log
 information, warnings, errors, and progress updates.
 */
public protocol LoggerBase {
  /// Logs an informational message usefull to developers but not the general users
  func dev(_ message: String)
  /// Logs an informational message.
  func info(_ message: String)
  /// Logs a warning message.
  func warning(_ message: String)
  /// Logs an error message.
  func error(_ message: String)
  /**
   Logs a progress message with a progress value.

   - Parameters:
   - message: A message describing the current operation.
   - progress: A value between 0.0 and 1.0 representing progress.
   */
  func progress(_ message: String, _ progress: Double)

  /**
   Sets the minimum log level. Messages below this level will be ignored.

   - Parameter level: The minimum `LogLevel` to log.
   */
  func setMinimumLogLevel(_ level: LogLevel)
}

// MARK: - Shared DateFormatter

internal enum SharedFormatter {
  /// ISO8601 date formatter configured with Internet date-time options.
  static let iso8601: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()
}

// MARK: - MultiplexLogger

/**
 A logger that forwards log messages to multiple destinations.

 Each destination is paired with a minimum `LogLevel`. Only messages
 whose level is greater than or equal to that minimum are forwarded.
 */
public class MultiplexLogger: LoggerBase {
  /// Tuples of logger instances
  private var loggers: [LoggerBase]

  /**
   Initializes a new empty `MultiplexLogger`.
   */
  public init() {
    self.loggers = []
  }

  /**
   Initializes a new `MultiplexLogger`.

   - Parameter loggers: Array of  loggers
   */
  public init(loggers: [LoggerBase]) {
    self.loggers = loggers
  }

  /**
   Sets the minimum log level. Messages below this level will be ignored.

   - Parameter level: The minimum `LogLevel` to log.
   */
  public func setMinimumLogLevel(_ level: LogLevel) {
    for logger in self.loggers {
      logger.setMinimumLogLevel(level)
    }
  }


  /**
   Adds a new logger destination at runtime.

   - Parameters:
   - logger: The `LoggerBase` instance to add.
   */
  public func add(logger: LoggerBase) {
    self.loggers.append(logger)
  }

  /**
   Logs an informational message .

   - Parameter message: The message to log.
   */
  public func info(_ message: String) {
    for logger in self.loggers{
      logger.info(message)
    }
  }

  /**
   Logs an informational message  for developers

   - Parameter message: The message to log.
   */
  public func dev(_ message: String) {
    for logger in self.loggers {
      logger.dev(message)
    }
  }

  /**
   Logs a warning message .

   - Parameter message: The warning message.
   */
  public func warning(_ message: String) {
    for logger in self.loggers {
      logger.warning(message)
    }
  }

  /**
   Logs an error message .

   - Parameter message: The error message.
   */
  public func error(_ message: String) {
    for logger in self.loggers {
      logger.error(message)
    }
  }

  /**
   Logs a progress message .

   - Parameters:
   - message: A message describing the current operation.
   - progress: A value between 0.0 and 1.0 representing progress.
   */
  public func progress(_ message: String, _ progress: Double) {
    for logger in self.loggers {
      logger.progress(message, progress)
    }
  }
}

// MARK: - OSLogger

/**
 A logger that sends log messages to Apple's Unified Logging System.

 Uses `os.Logger` to log messages with appropriate log levels.
 */
public class OSLogger: LoggerBase {
  /// The underlying OS logger instance.
  private let logger: os.Logger

  /// The level at with this logger will log messages
  private var minimumLogLevel: LogLevel = .progress

  /**
   Initializes a new `OSLogger`.

   - Parameters:
   - subsystem: The logging subsystem identifier.
   - category: The logging category.
   */
  public init(subsystem: String, category: String) {
    self.logger = os.Logger(subsystem: subsystem, category: category)
  }

  /// Logs an informational message for develoeprs
  public func dev(_ message: String) {
    if minimumLogLevel <= .dev {
      logger.info("\(message, privacy: .public)")
    }
  }

  /// Logs an informational message.
  public func info(_ message: String) {
    if minimumLogLevel <= .info {
      logger.info("\(message, privacy: .public)")
    }
  }

  /// Logs a warning message.
  public func warning(_ message: String) {
    if minimumLogLevel <= .warning {
      logger.warning("\(message, privacy: .public)")
    }
  }

  /// Logs an error message.
  public func error(_ message: String) {
    logger.error("\(message, privacy: .public)")
  }

  /**
   Logs a progress message with percentage display.

   - Parameters:
   - message: A message describing the current operation.
   - progress: A value between 0.0 and 1.0 representing progress.
   */
  public func progress(_ message: String, _ progress: Double) {
    let percentage = Int(progress * 100)
    logger.log("\(message, privacy: .public) - Progress: \(percentage)%")
  }

  /**
   Sets the minimum log level. Messages below this level will be ignored.

   - Parameter level: The minimum `LogLevel` to log.
   */
  public func setMinimumLogLevel(_ level: LogLevel) {
    self.minimumLogLevel = level
  }
}

// MARK: - FileLogger

/**
 A logger that writes log messages to a file.

 Supports log rotation when file size exceeds `maxFileSize`,
 and optional compression of rotated logs.
 */
public class FileLogger: LoggerBase {
  /// URL of the log file.
  private let logFile: URL
  /// Maximum file size before rotation.
  private let maxFileSize: Int
  /// If `true`, flushes to disk after each write.
  private let flushImmediately: Bool
  /// If `true`, compresses rotated logs.
  private let enableCompression: Bool
  /// The level at with this logger will log messages
  private var minimumLogLevel: LogLevel = .progress

  /**
   Initializes a new `FileLogger`.

   - Parameters:
   - logFilePath: Path to the log file.
   - maxFileSize: Max file size in bytes before rotation (default: 1MB).
   - flushImmediately: Flush after each write (default: `true`).
   - enableCompression: Compress rotated logs (default: `false`).
   */
  public init(logFilePath: String = "/tmp/app_log.txt",
              maxFileSize: Int = 1024 * 1024,
              flushImmediately: Bool = true,
              enableCompression: Bool = false) {
    self.logFile = URL(fileURLWithPath: logFilePath)
    self.maxFileSize = maxFileSize
    self.flushImmediately = flushImmediately
    self.enableCompression = enableCompression
  }

  /**
   Writes a log message to file, prepending a timestamp.

   - Parameter message: The message to log.
   */
  private func logToFile(_ message: String) {
    let timestamp = SharedFormatter.iso8601.string(from: Date())
    let logMessage = "\(timestamp) \(message)\n"
    rotateLogIfNeeded()
    do {
      if FileManager.default.fileExists(atPath: logFile.path) {
        let fileHandle = try FileHandle(forWritingTo: logFile)
        fileHandle.seekToEndOfFile()
        fileHandle.write(logMessage.data(using: .utf8)!)
        if flushImmediately { fileHandle.synchronizeFile() }
        fileHandle.closeFile()
      } else {
        try logMessage.data(using: .utf8)?.write(to: logFile, options: .atomic)
      }
    } catch {
      // Failed to write log file; error is silently ignored.
    }
  }

  /**
   Rotates the log file if its size exceeds `maxFileSize`.

   Moves the current log to an archive with `.old.log` extension,
   and compresses it if `enableCompression` is `true`.
   */
  private func rotateLogIfNeeded() {
    guard let fileSize = try? FileManager.default.attributesOfItem(atPath: logFile.path)[.size] as? Int else {
      return
    }
    if fileSize >= maxFileSize {
      let archiveURL = logFile.deletingPathExtension().appendingPathExtension("old.log")
      do {
        if FileManager.default.fileExists(atPath: archiveURL.path) {
          try FileManager.default.removeItem(at: archiveURL)
        }
        try FileManager.default.moveItem(at: logFile, to: archiveURL)
        if enableCompression {
          compressFile(at: archiveURL)
        }
      } catch {
        // Failed to rotate or compress; error is silently ignored.
      }
    }
  }

  /**
   Compresses a log file at the given URL using zlib and writes it with `.gz` extension.

   - Parameter fileURL: The URL of the file to compress.
   */
  private func compressFile(at fileURL: URL) {
    let compressedURL = fileURL.appendingPathExtension("gz")
    do {
      let inputData = try Data(contentsOf: fileURL)
      if let compressedData = gzipCompress(inputData) {
        try compressedData.write(to: compressedURL)
        try FileManager.default.removeItem(at: fileURL)
      }
    } catch {
      // Compression failure is silently ignored.
    }
  }

  /**
   Compresses in-memory `Data` using the zlib algorithm.

   - Parameter data: The data to compress.
   - Returns: Compressed data on success, or `nil` on failure.
   */
  private func gzipCompress(_ data: Data) -> Data? {
    return data.withUnsafeBytes { rawBuffer in
      guard let src = rawBuffer.baseAddress else { return nil }
      let dest = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
      defer { dest.deallocate() }
      let compressedSize = compression_encode_buffer(
        dest, data.count,
        src.assumingMemoryBound(to: UInt8.self), data.count,
        nil, COMPRESSION_ZLIB
      )
      guard compressedSize > 0 else { return nil }
      return Data(bytes: dest, count: compressedSize)
    }
  }

  /// Logs an informational message for developers to file.
  public func dev(_ message: String) {
    if minimumLogLevel <= .dev {
      logToFile("[DEV] \(message)")
    }
  }
  /// Logs an informational message to file.
  public func info(_ message: String) {
    if minimumLogLevel <= .info {
      logToFile("[INFO] \(message)")
    }
  }
  /// Logs a warning message to file.
  public func warning(_ message: String) {
    if minimumLogLevel <= .warning {
      logToFile("[WARNING] \(message)")
    }
  }
  /// Logs an error message to file.
  public func error(_ message: String) {
    logToFile("[ERROR] \(message)")
  }
  /**
   Logs a progress message to file with percentage.

   - Parameters:
   - message: A message describing the operation.
   - progress: A value between 0.0 and 1.0.
   */
  public func progress(_ message: String, _ progress: Double) {
    logToFile("[PROGRESS] \(message) - \(Int(progress * 100))%")
  }

  /**
   Sets the minimum log level. Messages below this level will be ignored.

   - Parameter level: The minimum `LogLevel` to log.
   */
  public func setMinimumLogLevel(_ level: LogLevel) {
    self.minimumLogLevel = level
  }
}

// MARK: - PrintfLogger

/**
 A logger that prints messages to the console, including an ASCII progress bar.

 Supports colored output and optional emoji-based formatting.
 */
public class PrintfLogger: LoggerBase {
  /// Formats for displaying estimated time remaining.
  public enum ETAFormat {
    case mmss       // "03:45"
    case seconds    // "225 seconds"
    case hhmmss     // "01:03:45"
    case rawSeconds // "225.34s"
  }

  private let useColors: Bool
  private let etaFormat: ETAFormat
  private let spinnerFrames = ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"]
  private var spinnerIndex = 0
  private var startTime: Date?
  /// The level at with this logger will log messages
  private var minimumLogLevel: LogLevel = .progress


  /**
   Initializes a new `PrintfLogger`.

   - Parameters:
   - useColors: Enable ANSI color output (default: `true`).
   - etaFormat: Format for ETA display (default: `.mmss`).
   */
  public init(useColors: Bool = true, etaFormat: ETAFormat = .mmss) {
    self.useColors = useColors
    self.etaFormat = etaFormat
  }

  /**
   Wraps text in ANSI color codes if colors are enabled.

   - Parameters:
   - text: The text to color.
   - color: The ANSI color code string.
   - Returns: Colored text if `useColors` is `true`; otherwise original text.
   */
  private func coloredText(_ text: String, color: String) -> String {
    return useColors ? "\(color)\(text)\u{001B}[0m" : text
  }

  /**
   Prints a log message with optional emoji and ANSI color.

   - Parameters:
   - message: The message to print.
   - color: ANSI color code.
   - emoji: Optional emoji prefix.
   - level: Log level label.
   */
  private func log(_ message: String, color: String, level: String) {
    let prefix = "[\(level)] "
    print(coloredText("\(prefix)\(message)", color: color))
    fflush(stdout)
  }

  /// Prints an informational message for developers.
  public func dev(_ message: String) {
    if minimumLogLevel <= .dev {
      log(message, color: "\u{001B}[36m", level: "DEV")
    }
  }
  /// Prints an informational message.
  public func info(_ message: String) {
    if minimumLogLevel <= .info {
      log(message, color: "\u{001B}[32m", level: "INFO")
    }
  }
  /// Prints a warning message.
  public func warning(_ message: String) {
    if minimumLogLevel <= .warning {
      log(message, color: "\u{001B}[33m", level: "WARNING")
    }
  }
  /// Prints an error message.
  public func error(_ message: String) {
    log(message, color: "\u{001B}[31m", level: "ERROR")
  }

  /**
   Displays a progress bar, percentage, ETA, and spinner in the console.

   - Parameters:
   - message: A message describing the current operation.
   - progress: A value between 0.0 and 1.0 representing progress.
   */
  public func progress(_ message: String, _ progress: Double) {
    guard minimumLogLevel <= .progress else { return }

    let barLength = 30
    let filled = Int(progress * Double(barLength))
    let empty = barLength - filled
    let bar = "[" + String(repeating: "█", count: filled)
    + String(repeating: "-", count: empty) + "]"
    let percentage = Int(progress * 100)

    if progress > 0.0 && startTime == nil {
      startTime = Date()
    }
    let eta = calculateETA(progress)
    let spinner = spinnerFrames[spinnerIndex]
    spinnerIndex = (spinnerIndex + 1) % spinnerFrames.count
    let prefix = "\(spinner)"
    let msg = "\r\(prefix) \(message) \(bar) \(percentage)% ETA: \(eta)\u{001B}[K"
    print(coloredText(msg, color: "\u{001B}[36m"), terminator: "")
    fflush(stdout)

    if progress >= 1.0 {
      print("")
      startTime = nil
    }
  }

  /**
   Calculates the estimated time remaining based on progress.

   - Parameter progress: A value between 0.0 and 1.0.
   - Returns: Formatted ETA string.
   */
  private func calculateETA(_ progress: Double) -> String {
    guard let start = startTime, progress > 0.0 else {
      return "--:--"
    }
    let elapsed = Date().timeIntervalSince(start)
    let total = elapsed / progress
    let remaining = total - elapsed
    switch etaFormat {
      case .mmss:
        let m = Int(remaining) / 60
        let s = Int(remaining) % 60
        return String(format: "%02d:%02d", m, s)
      case .seconds:
        return "\(Int(remaining)) seconds"
      case .hhmmss:
        let h = Int(remaining) / 3600
        let m = (Int(remaining) % 3600) / 60
        let s = Int(remaining) % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
      case .rawSeconds:
        return String(format: "%.2fs", remaining)
    }
  }

  /**
   Sets the minimum log level. Messages below this level will be ignored.

   - Parameter level: The minimum `LogLevel` to log.
   */
  public func setMinimumLogLevel(_ level: LogLevel) {
    self.minimumLogLevel = level
  }
}

// MARK: - HTMLLogger

/**
 A logger that writes log messages to an HTML file for web display.

 Generates HTML with filtering, toggling, and styled log entries.
 */
public class HTMLLogger: LoggerBase {
  /// URL of the HTML log file.
  private let logFile: URL
  /// If `true`, each log entry is prepended with a timestamp.
  private let enableTimestamp: Bool
  /// Indicates if the HTML file has been finalized.
  private var isFinalized = false
  /// The level at with this logger will log messages
  private var minimumLogLevel: LogLevel = .progress

  /**
   Initializes a new `HTMLLogger`.

   - Parameters:
   - logFilePath: Path to the HTML log file.
   - enableTimestamp: Include timestamp in entries (default: `true`).
   */
  public init(logFilePath: String = "/tmp/log.html", enableTimestamp: Bool = true) {
    self.logFile = URL(fileURLWithPath: logFilePath)
    self.enableTimestamp = enableTimestamp
    if !FileManager.default.fileExists(atPath: logFile.path) {
      initializeHTMLLogFile()
    }
  }

  /**
   Writes the initial HTML header with CSS and JavaScript to the log file.
   */
  private func initializeHTMLLogFile() {
    let htmlHeader = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Application Log</title>
            <style>
                body { font-family: Arial, sans-serif; margin: 20px; background: #1e1e1e; color: #ddd; text-align: center; }
                .log-container { max-width: 900px; margin: auto; background: #2e2e2e; padding: 10px; border-radius: 5px; text-align: left; }
                .log-entry { margin: 5px 0; padding: 8px; border-radius: 5px; }
                .dev { background: #007acc; color: #fff; }
                .info { background: #d0e7ff; color: #fff; }
                .warning { background: #ffcc00; color: #000; }
                .error { background: #ff4444; color: #fff; }
                .progress { background: #44ff44; color: #000; }
                #logFilter { width: 100%; padding: 8px; margin-bottom: 10px; }
                .hidden { display: none; }
            </style>
            <script>
                function filterLogs() {
                    let filter = document.getElementById('logFilter').value.toLowerCase();
                    let logs = document.getElementsByClassName('log-entry');
                    for (let log of logs) {
                        log.style.display = log.innerText.toLowerCase().includes(filter) ? "block" : "none";
                    }
                }
                function toggleVisibility(className) {
                    let logs = document.getElementsByClassName(className);
                    for (let log of logs) {
                        log.classList.toggle('hidden');
                    }
                }
            </script>
        </head>
        <body>
        <h2>Application Log</h2>
        <input type="text" id="logFilter" onkeyup="filterLogs()" placeholder="Search logs...">
        <button onclick="toggleVisibility('dev')">Toggle DEVELOPER INFO</button>
        <button onclick="toggleVisibility('info')">Toggle INFO</button>
        <button onclick="toggleVisibility('warning')">Toggle WARNING</button>
        <button onclick="toggleVisibility('error')">Toggle ERROR</button>
        <button onclick="toggleVisibility('progress')">Toggle PROGRESS</button>
        <div class="log-container">
        """
    do {
      try htmlHeader.write(to: logFile, atomically: true, encoding: .utf8)
    } catch {
      print("Failed to create HTML log file: \(error)")
    }
  }

  /**
   Appends a log entry to the HTML file with appropriate CSS class.

   - Parameters:
   - message: The log message.
   - level: The log level label.
   - cssClass: CSS class for styling the entry.
   */
  private func appendLogEntry(_ message: String, level: String, cssClass: String) {
    let timestamp = enableTimestamp ? SharedFormatter.iso8601.string(from: Date()) : ""
    let entry = """
            <div class="log-entry \(cssClass)">
                <strong>\(level)</strong>: \(timestamp) \(message)
            </div>
            """
    do {
      let handle = try FileHandle(forWritingTo: logFile)
      handle.seekToEndOfFile()
      handle.write(entry.data(using: .utf8)!)
      handle.closeFile()
    } catch {
      // Failed to write entry; error is silently ignored.
    }
  }

  /// Logs an informational message for developer in HTML.
  public func dev(_ message: String) {
    if minimumLogLevel <= .dev {
      appendLogEntry(message, level: "DEV", cssClass: "dev")
    }
  }
  /// Logs an informational message in HTML.
  public func info(_ message: String) {
    if minimumLogLevel <= .info {
      appendLogEntry(message, level: "INFO", cssClass: "info")
    }
  }
  /// Logs a warning message in HTML.
  public func warning(_ message: String) {
    if minimumLogLevel <= .warning {
      appendLogEntry(message, level: "WARNING", cssClass: "warning")
    }
  }
  /// Logs an error message in HTML.
  public func error(_ message: String) {
    appendLogEntry(message, level: "ERROR", cssClass: "error")
  }
  /**
   Logs a progress message in HTML with percentage.

   - Parameters:
   - message: A message describing the current operation.
   - progress: A value between 0.0 and 1.0.
   */
  public func progress(_ message: String, _ progress: Double) {
    if minimumLogLevel <= .progress {
      appendLogEntry("\(message) - \(Int(progress * 100))%", level: "PROGRESS", cssClass: "progress")
    }
  }

  deinit {
    closeLogFile()
  }

  /**
   Finalizes the HTML log file by appending closing tags.
   */
  private func closeLogFile() {
    guard !isFinalized else { return }
    let footer = """
        </div></body></html>
        """
    do {
      let handle = try FileHandle(forWritingTo: logFile)
      handle.seekToEndOfFile()
      handle.write(footer.data(using: .utf8)!)
      handle.closeFile()
      isFinalized = true
    } catch {
      // Failed to finalize; error is silently ignored.
    }
  }
  /**
   Sets the minimum log level. Messages below this level will be ignored.

   - Parameter level: The minimum `LogLevel` to log.
   */
  public func setMinimumLogLevel(_ level: LogLevel) {
    self.minimumLogLevel = level
  }
}

// MARK: - JSONLogger

/**
 A logger that writes log messages in JSON format to a file.
 */
public class JSONLogger: LoggerBase {
  /// URL of the JSON log file.
  private let logFile: URL
  /// The level at with this logger will log messages
  private var minimumLogLevel: LogLevel = .progress

  /**
   Initializes a new `JSONLogger`.

   - Parameter logFilePath: Path for the JSON log file.
   */
  public init(logFilePath: String = "/tmp/logs.json") {
    self.logFile = URL(fileURLWithPath: logFilePath)
    if !FileManager.default.fileExists(atPath: logFile.path) {
      initializeJSONLogFile()
    }
  }

  /**
   Creates an empty JSON array file to start logging.
   */
  private func initializeJSONLogFile() {
    do {
      let empty: [Any] = []
      let data = try JSONSerialization.data(withJSONObject: empty, options: .prettyPrinted)
      try data.write(to: logFile)
    } catch {
      // Failed to initialize JSON log file; error is silently ignored.
    }
  }

  /**
   Appends a new log entry object to the JSON file array.

   - Parameters:
   - level: Log level string.
   - message: The log message.
   */
  private func logToFile(_ level: String, _ message: String) {
    let timestamp = SharedFormatter.iso8601.string(from: Date())
    let entry: [String: Any] = [
      "timestamp": timestamp,
      "level": level,
      "message": message
    ]
    do {
      let existing = try Data(contentsOf: logFile)
      var array = (try JSONSerialization.jsonObject(with: existing) as? [[String: Any]]) ?? []
      array.append(entry)
      let data = try JSONSerialization.data(withJSONObject: array, options: .prettyPrinted)
      try data.write(to: logFile)
    } catch {
      // Failed to append JSON entry; error is silently ignored.
    }
  }

  /// Logs an informational developer JSON entry.
  public func dev(_ message: String) {
    if minimumLogLevel <= .info {
      logToFile("DEV", message)
    }
  }
  /// Logs an informational JSON entry.
  public func info(_ message: String) {
    if minimumLogLevel <= .info {
      logToFile("INFO", message)
    }
  }
  /// Logs a warning JSON entry.
  public func warning(_ message: String) {
    if minimumLogLevel <= .warning {
      logToFile("WARNING", message)
    }
  }
  /// Logs an error JSON entry.
  public func error(_ message: String) {
    logToFile("ERROR", message)
  }
  /**
   Logs a progress JSON entry with percentage.

   - Parameters:
   - message: A message describing the operation.
   - progress: Value between 0.0 and 1.0.
   */
  public func progress(_ message: String, _ progress: Double) {
    if minimumLogLevel <= .progress {
      logToFile("PROGRESS", "\(message) - \(Int(progress * 100))%")
    }
  }

  /**
   Sets the minimum log level. Messages below this level will be ignored.

   - Parameter level: The minimum `LogLevel` to log.
   */
  public func setMinimumLogLevel(_ level: LogLevel) {
    self.minimumLogLevel = level
  }
}

// MARK: - CSVLogger

/**
 A logger that writes log messages as CSV records to a file.
 */
public class CSVLogger: LoggerBase {
  /// URL of the CSV log file.
  private let logFile: URL
  /// The level at with this logger will log messages
  private var minimumLogLevel: LogLevel = .progress

  /**
   Initializes a new `CSVLogger`.

   - Parameter logFilePath: Path for the CSV log file.
   */
  public init(logFilePath: String = "/tmp/logs.csv") {
    self.logFile = URL(fileURLWithPath: logFilePath)
    if !FileManager.default.fileExists(atPath: logFile.path) {
      initializeCSVLogFile()
    }
  }

  /**
   Writes the CSV header row (Timestamp, Level, Message).
   */
  private func initializeCSVLogFile() {
    let header = "Timestamp,Level,Message\n"
    do {
      try header.write(to: logFile, atomically: true, encoding: .utf8)
    } catch {
      // Failed to create CSV log file; error is silently ignored.
    }
  }

  /**
   Escapes a CSV field by doubling quotes and wrapping in quotes.

   - Parameter value: The field value.
   - Returns: The escaped CSV field.
   */
  private func escapeCSVField(_ value: String) -> String {
    let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
    return "\"\(escaped)\""
  }

  /**
   Appends a CSV record with timestamp, level, and message.

   - Parameters:
   - level: Log level string.
   - message: The log message.
   */
  private func logToFile(_ level: String, _ message: String) {
    let timestamp = SharedFormatter.iso8601.string(from: Date())
    let record = "\(timestamp),\(level),\(escapeCSVField(message))\n"
    do {
      let handle = try FileHandle(forWritingTo: logFile)
      handle.seekToEndOfFile()
      handle.write(record.data(using: .utf8)!)
      handle.closeFile()
    } catch {
      // Failed to append CSV record; error is silently ignored.
    }
  }

  /// Logs an informational developer CSV record.
  public func dev(_ message: String) {
    if minimumLogLevel <= .dev {
      logToFile("DEV", message)
    }
  }
  /// Logs an informational CSV record.
  public func info(_ message: String) {
    if minimumLogLevel <= .info {
      logToFile("INFO", message)
    }
  }
  /// Logs a warning CSV record.
  public func warning(_ message: String) {
    if minimumLogLevel <= .warning {
      logToFile("WARNING", message)
    }
  }
  /// Logs an error CSV record.
  public func error(_ message: String) {
    logToFile("ERROR", message)
  }
  /**
   Logs a progress CSV record with percentage.

   - Parameters:
   - message: A description of the operation.
   - progress: Value between 0.0 and 1.0.
   */
  public func progress(_ message: String, _ progress: Double) {
    if minimumLogLevel <= .progress {
      logToFile("PROGRESS", "\(message) - \(Int(progress * 100))%")
    }
  }

  /**
   Sets the minimum log level. Messages below this level will be ignored.

   - Parameter level: The minimum `LogLevel` to log.
   */
  public func setMinimumLogLevel(_ level: LogLevel) {
    self.minimumLogLevel = level
  }
}

// MARK: - GUILogger

/**
 A logger that updates UI state via SwiftUI bindings.

 Holds optional bindings for log text, progress text, and progress value.
 Each log call updates the corresponding binding on the main thread.
 */
public class GUILogger: LoggerBase {
  /// Binding to multi-line log text.
  private var logBinding: Binding<String>?
  /// Binding to progress description text.
  private var progressTextBinding: Binding<String>?
  /// Binding to progress value.
  private var progressBinding: Binding<Double>?
  /// The level at with this logger will log messages
  private var minimumLogLevel: LogLevel = .progress


  /**
   Sets or updates the binding for multi-line log text.

   - Parameter newLog: Binding to the string that holds log text.
   */
  public func setLogBinding(_ newLog: Binding<String>) {
    DispatchQueue.main.async {
      self.logBinding = newLog
    }
  }

  /**
   Sets or updates bindings for progress text and value.

   - Parameters:
   - newText: Binding to progress description string.
   - newProgress: Binding to progress value.
   */
  public func setProgressBinding(_ newText: Binding<String>, _ newProgress: Binding<Double>) {
    DispatchQueue.main.async {
      self.progressTextBinding = newText
      self.progressBinding = newProgress
    }
  }

  /**
   Appends a message to the log binding on the main thread.

   - Parameter message: The message to append.
   */
  private func appendLog(_ message: String) {
    DispatchQueue.main.async {
      if let current = self.logBinding?.wrappedValue {
        self.logBinding?.wrappedValue = current + message + "\n"
      } else {
        self.logBinding?.wrappedValue = message + "\n"
      }
    }
  }

  /// Appends an informational developer message to the UI log.
  public func dev(_ message: String) {
    if minimumLogLevel <= .dev {
      appendLog(message)
    }
  }
  /// Appends an informational message to the UI log.
  public func info(_ message: String) {
    if minimumLogLevel <= .info {
      appendLog(message)
    }
  }
  /// Appends a warning message to the UI log.
  public func warning(_ message: String) {
    if minimumLogLevel <= .warning {
      appendLog("[WARNING] \(message)")
    }
  }
  /// Appends an error message to the UI log.
  public func error(_ message: String) {
    appendLog("[ERROR] \(message)")
  }
  /**
   Updates the progress bindings on the main thread.

   - Parameters:
   - message: The progress description.
   - progress: A value between 0.0 and 1.0.
   */
  public func progress(_ message: String, _ progress: Double) {
    if minimumLogLevel <= .progress {
      DispatchQueue.main.async {
        self.progressTextBinding?.wrappedValue = message
        self.progressBinding?.wrappedValue = progress
      }
    }
  }
  /**
   Sets the minimum log level. Messages below this level will be ignored.

   - Parameter level: The minimum `LogLevel` to log.
   */
  public func setMinimumLogLevel(_ level: LogLevel) {
    self.minimumLogLevel = level
  }
}

/*
 Copyright (c) 2025 Computer Graphics and Visualization Group, University of Duisburg-
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
