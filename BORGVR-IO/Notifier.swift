// MARK: - NotificationLevel

/**
 Defines various log levels for filtering messages.

 The log levels are ordered by severity:
 - dev: Informational messages for developers only (least severe)
 - progress: Detailed progress updates
 - info: Informational messages
 - warning: Warnings about potential issues
 - error: Error messages (most severe)
 */
public enum NotificationLevel: Int, Comparable {
  /// Notifications delivered silently
  case silent = 0
  /// Normal Notifications
  case message = 1
  /// Critical Notifications
  case critical = 2

  /**
   Enables comparing notification levels by their raw integer values.

   - Parameters:
   - lhs: The left-hand side `NotificationLevel`.
   - rhs: The right-hand side `NotificationLevel`.
   - Returns: `true` if `lhs.rawValue < rhs.rawValue`.
   */
  public static func < (lhs: NotificationLevel, rhs: NotificationLevel) -> Bool {
    return lhs.rawValue < rhs.rawValue
  }
}

// MARK: - Notification Protocol

/**
 The `NotificationBase` protocol defines the core logging methods.

 Any Notifier conforming to `NotificationBase` must implement methods to notify
 */
public protocol NotificationBase {
  /// Silent Notifictations (e.g. it's cold outside)
  func silent(title: String, message: String)
  /// Normal Notifications (e.g. we are in icy water)
  func normal(title: String, message: String)
  /// Critical Notifications (e.g. iceberg dead ahead)
  func critical(title: String, message: String)
}

/*
 Copyright (c) 2025 Computer Graphics and Visualization Group, University of
 Duisburg-Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of
 this software and associated documentation files (the "Software"), to deal in the
 Software without restriction, including without limitation the rights to use,
 copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the
 Software, and to permit persons to whom the Software is furnished to do so, subject
 to the following conditions:

 The above copyright notice and this permission notice shall be included in all copies
 or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
 CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR
 THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
