import Foundation

enum RenderMode: UInt8, CaseIterable, Identifiable, CustomStringConvertible {
  case transferFunction1DLighting = 1
  case transferFunction1D = 0
  case isoValue = 2

  var id: UInt8 { rawValue }

  var description: String {
    switch self {
      case .transferFunction1D:
        return String(localized: "Transfer Function")
      case .transferFunction1DLighting:
        return String(localized: "Transfer function + lighting")
      case .isoValue:
        return String(localized: "Isovalue")
    }
  }

  func serialize() -> UInt8 {
    rawValue
  }

  static func deserialize(_ byte: UInt8) -> RenderMode {
    RenderMode(rawValue: byte) ?? .transferFunction1D
  }
}

/*
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of Duisburg-Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of this
 software and associated documentation files (the "Software"), to deal in the Software
 without restriction, including without limitation the rights to use, copy, modify,
 merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 permit persons to whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included in all copies or
 substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
 BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
 OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
 IN THE SOFTWARE.
 */
