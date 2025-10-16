import Foundation

final class KeyValuePairHandler {
  private var storage: [String: String] = [:]

  // MARK: - Inits

  /// Empty
  init() {}

  /// Splits on newlines, ignores blank lines.
  convenience init(text: String) {
    self.init()
    add(text: text)
  }

  // MARK: - Parsing / Mutating

  /// Add/update pairs from a synthesized string
  /// - Each non-empty line is split at the FIRST whitespace:
  ///   key = prefix, value = rest (trimmed)
  func add(text: String) {
    // Handle both \n and \r\n cleanly
    text.split(whereSeparator: \.isNewline).forEach { lineSubstr in
      let raw = String(lineSubstr)
      guard let splitIdx = raw.firstIndex(where: { $0.isWhitespace }) else {
        // no whitespace → stop
        return
      }
      let key = String(raw[..<splitIdx])
      let value = String(raw[raw.index(after: splitIdx)...])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !key.isEmpty else { return }
      storage[key] = value
    }
  }

  /// Set a single pair
  func set<V: CustomStringConvertible>(_ key: String, _ value: V) {
    guard !key.isEmpty else { return }
    storage[key] = String(describing: value)
  }

  @discardableResult
  func remove(_ key: String) -> String? { storage.removeValue(forKey: key) }

  // MARK: - Access

  func string(for key: String) -> String? { storage[key] }

  func value<T: LosslessStringConvertible>(for key: String) -> T? {
    guard let s = storage[key] else { return nil }
    return T(s)
  }

  func int(for key: String) -> Int? { value(for: key) }
  func double(for key: String) -> Double? { value(for: key) }

  func bool(for key: String) -> Bool? {
    guard let s = storage[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
    switch s {
      case "true", "yes", "on", "1":  return true
      case "false", "no", "off", "0": return false
      default: return nil
    }
  }

  // Writable raw subscript
  subscript(_ key: String) -> String? {
    get { storage[key] }
    set { storage[key] = newValue }
  }

  // Read-only typed subscript
  subscript<T: LosslessStringConvertible>(typed key: String) -> T? {
    value(for: key)
  }

  // MARK: - Synthesis

  struct SynthesisOptions {
    var sortKeys: Bool = false
    var keyWidth: Int? = nil
    var separator: String = "\n"
    var includeFinalSeparator: Bool = true
  }

  func lines(options: SynthesisOptions = .init()) -> [String] {
    let keys = options.sortKeys ? storage.keys.sorted() : Array(storage.keys)
    return keys.map { key in
      let left: String
      if let width = options.keyWidth, width > key.count {
        left = key.padding(toLength: width, withPad: " ", startingAt: 0)
      } else {
        left = key
      }
      return "\(left) \(storage[key] ?? "")"
    }
  }

  func synthesize(options: SynthesisOptions = .init()) -> String {
    let body = lines(options: options).joined(separator: options.separator)
    return options.includeFinalSeparator ? body + options.separator : body
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
