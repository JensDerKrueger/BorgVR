import Foundation

enum WebAssetProvider {
  static let resourceDirectoryName = "web"

  static func rootURL(in bundle: Bundle = .main) -> URL? {
    bundle.url(forResource: resourceDirectoryName, withExtension: nil)
  }

  static func url(for requestPath: String, in bundle: Bundle = .main) -> URL? {
    guard let rootURL = rootURL(in: bundle) else {
      return nil
    }

    guard let normalizedPath = normalizedRequestPath(requestPath) else {
      return nil
    }

    return rootURL.appendingPathComponent(normalizedPath, isDirectory: false)
  }

  static func contentType(for path: String) -> String {
    switch URL(fileURLWithPath: path).pathExtension.lowercased() {
    case "html":
      return "text/html; charset=utf-8"
    case "css":
      return "text/css; charset=utf-8"
    case "js":
      return "text/javascript; charset=utf-8"
    case "json":
      return "application/json; charset=utf-8"
    case "jpg", "jpeg":
      return "image/jpeg"
    case "png":
      return "image/png"
    case "svg":
      return "image/svg+xml"
    case "ico":
      return "image/x-icon"
    default:
      return "application/octet-stream"
    }
  }

  private static func normalizedRequestPath(_ requestPath: String) -> String? {
    let pathWithoutQuery = requestPath.split(separator: "?", maxSplits: 1).first ?? ""
    let trimmedPath = pathWithoutQuery.split(separator: "#", maxSplits: 1).first ?? ""
    let components = trimmedPath
      .split(separator: "/", omittingEmptySubsequences: true)
      .map(String.init)

    guard !components.contains("..") else {
      return nil
    }

    let normalized = components.joined(separator: "/")
    return normalized.isEmpty ? "index.html" : normalized
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
