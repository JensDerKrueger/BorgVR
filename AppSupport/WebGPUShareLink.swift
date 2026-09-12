import Darwin
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum WebGPUShareLink {
  static func serverBaseURL(port: Int) -> URL? {
    guard let host = localNetworkHost() else { return nil }
    var components = URLComponents()
    components.scheme = "https"
    components.host = host
    components.port = port
    components.path = "/"
    return components.url
  }

  static func datasetURL(
    baseURL: URL,
    datasetID: String,
    transferFunction: TransferFunction1D,
    renderMode: RenderMode,
    normalizedIsoValue: Float
  ) -> URL? {
    var queryItems = [
      URLQueryItem(name: "ID", value: datasetID),
      URLQueryItem(name: "mode", value: renderModeURLValue(renderMode))
    ]

    if renderMode == .isoValue {
      queryItems.append(URLQueryItem(name: "iso", value: normalizedIsoValueURLString(normalizedIsoValue)))
    } else {
      guard let encodedTransferFunction = encodeTransferFunctionURLValue(transferFunction) else {
        return nil
      }
      queryItems.append(URLQueryItem(name: "TF", value: encodedTransferFunction))
    }

    var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
    components?.path = "/"
    components?.queryItems = queryItems
    return components?.url
  }

  static func copyToPasteboard(_ text: String) {
#if canImport(UIKit)
    UIPasteboard.general.string = text
#elseif canImport(AppKit)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
#endif
  }

  private static func encodeTransferFunctionURLValue(_ transferFunction: TransferFunction1D) -> String? {
    let nativeBytes = [UInt8](transferFunction.serialize())
    let nativeCompressed = encodeLZ4Block(nativeBytes)
    let nativeToken = "l.\(nativeBytes.count).\(base64URL(nativeCompressed))"

    let rgbaBytes = rgbaBytes(for: transferFunction)
    let deltaCompressed = encodeLZ4Block(deltaEncodeRGBA(rgbaBytes))
    let deltaToken = "d.\(rgbaBytes.count / 4).\(base64URL(deltaCompressed))"
    return deltaToken.count < nativeToken.count ? deltaToken : nativeToken
  }

  private static func renderModeURLValue(_ renderMode: RenderMode) -> String {
    switch renderMode {
      case .transferFunction1D:
        return "tf"
      case .transferFunction1DLighting:
        return "tf-lighting"
      case .isoValue:
        return "iso"
    }
  }

  private static func normalizedIsoValueURLString(_ value: Float) -> String {
    let clampedValue = min(max(value, 0), 1)
    return String(format: "%.6g", locale: Locale(identifier: "en_US_POSIX"), Double(clampedValue))
  }

  private static func rgbaBytes(for transferFunction: TransferFunction1D) -> [UInt8] {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(transferFunction.data.count * 4)
    for sample in transferFunction.data {
      bytes.append(sample.x)
      bytes.append(sample.y)
      bytes.append(sample.z)
      bytes.append(sample.w)
    }
    return bytes
  }

  private static func deltaEncodeRGBA(_ rgba: [UInt8]) -> [UInt8] {
    var result = Array(repeating: UInt8(0), count: rgba.count)
    for index in rgba.indices {
      if index < 4 {
        result[index] = rgba[index]
      } else {
        result[index] = UInt8(truncatingIfNeeded: Int(rgba[index]) - Int(rgba[index - 4]))
      }
    }
    return result
  }

  private static func encodeLZ4Block(_ source: [UInt8]) -> [UInt8] {
    guard !source.isEmpty else { return [] }

    var output: [UInt8] = []
    var table: [UInt32: Int] = [:]
    var anchor = 0
    var position = 0

    while position + 4 <= source.count {
      let sequence = readUInt32LE(source, at: position)
      let reference = table[sequence]
      table[sequence] = position

      if let reference,
         position - reference <= 65_535,
         source[reference] == source[position],
         source[reference + 1] == source[position + 1],
         source[reference + 2] == source[position + 2],
         source[reference + 3] == source[position + 3] {
        var matchLength = 4
        while position + matchLength < source.count,
              source[reference + matchLength] == source[position + matchLength] {
          matchLength += 1
        }

        emitLZ4Sequence(
          into: &output,
          source: source,
          literalStart: anchor,
          literalEnd: position,
          matchOffset: position - reference,
          matchLength: matchLength
        )

        let matchEnd = position + matchLength
        var fill = position + 1
        while fill + 4 <= matchEnd {
          table[readUInt32LE(source, at: fill)] = fill
          fill += 1
        }
        position = matchEnd
        anchor = position
      } else {
        position += 1
      }
    }

    emitLZ4Sequence(
      into: &output,
      source: source,
      literalStart: anchor,
      literalEnd: source.count,
      matchOffset: 0,
      matchLength: 0
    )
    return output
  }

  private static func emitLZ4Sequence(
    into output: inout [UInt8],
    source: [UInt8],
    literalStart: Int,
    literalEnd: Int,
    matchOffset: Int,
    matchLength: Int
  ) {
    let literalLength = literalEnd - literalStart
    let matchTokenLength = matchLength > 0 ? matchLength - 4 : 0
    output.append(UInt8((min(literalLength, 15) << 4) | min(matchTokenLength, 15)))

    if literalLength >= 15 {
      emitLZ4Length(literalLength - 15, into: &output)
    }

    if literalStart < literalEnd {
      output.append(contentsOf: source[literalStart..<literalEnd])
    }

    guard matchLength > 0 else { return }

    output.append(UInt8(matchOffset & 0xff))
    output.append(UInt8((matchOffset >> 8) & 0xff))
    if matchTokenLength >= 15 {
      emitLZ4Length(matchTokenLength - 15, into: &output)
    }
  }

  private static func emitLZ4Length(_ length: Int, into output: inout [UInt8]) {
    var remaining = length
    while remaining >= 255 {
      output.append(255)
      remaining -= 255
    }
    output.append(UInt8(remaining))
  }

  private static func readUInt32LE(_ data: [UInt8], at offset: Int) -> UInt32 {
    UInt32(data[offset]) |
      (UInt32(data[offset + 1]) << 8) |
      (UInt32(data[offset + 2]) << 16) |
      (UInt32(data[offset + 3]) << 24)
  }

  private static func base64URL(_ bytes: [UInt8]) -> String {
    Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func localNetworkHost() -> String? {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
      return nil
    }
    defer { freeifaddrs(interfaces) }

    var preferredAddresses: [String] = []
    var fallbackAddresses: [String] = []
    var pointer: UnsafeMutablePointer<ifaddrs>? = firstInterface
    while let interface = pointer?.pointee {
      defer { pointer = interface.ifa_next }

      let flags = Int32(interface.ifa_flags)
      guard (flags & IFF_UP) != 0,
            (flags & IFF_LOOPBACK) == 0,
            let addressPointer = interface.ifa_addr,
            addressPointer.pointee.sa_family == UInt8(AF_INET) else {
        continue
      }

      var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let result = getnameinfo(
        addressPointer,
        socklen_t(addressPointer.pointee.sa_len),
        &hostname,
        socklen_t(hostname.count),
        nil,
        0,
        NI_NUMERICHOST
      )
      guard result == 0 else { continue }

      let address = String(cString: hostname)
      let name = String(cString: interface.ifa_name)
      if name.hasPrefix("en") {
        preferredAddresses.append(address)
      } else {
        fallbackAddresses.append(address)
      }
    }

    return (preferredAddresses + fallbackAddresses).first
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
