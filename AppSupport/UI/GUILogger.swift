import SwiftUI

/// A logger that retains messages and publishes them to optional SwiftUI bindings.
public final class GUILogger: LoggerBase, @unchecked Sendable {
  private var logBinding: Binding<String>?
  private var logText = ""
  private var progressTextBinding: Binding<String>?
  private var progressBinding: Binding<Double>?
  private let filter = LogLevelFilter()

  public init() {}

  public func setLogBinding(_ newLog: Binding<String>) {
    DispatchQueue.main.async {
      self.logBinding = newLog
      self.logBinding?.wrappedValue = self.logText
    }
  }

  public func clear() {
    DispatchQueue.main.async {
      self.logText = ""
      self.logBinding?.wrappedValue = ""
    }
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
    DispatchQueue.main.async {
      self.logText += message + "\n"
      self.logBinding?.wrappedValue = self.logText
    }
  }

  private func localizedLogLevel(_ key: String, fallback: String) -> String {
    NSLocalizedString(key, tableName: nil, bundle: .main, value: fallback, comment: "Log level label")
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
