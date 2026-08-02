import Foundation

enum RuntimeMetalShaderLoaderError: LocalizedError {
  case missingShader(String)
  case missingInclude(String, URL)
  case recursiveInclude(String)

  var errorDescription: String? {
    switch self {
      case let .missingShader(name):
        return "\(name) wurde nicht im App-Bundle gefunden."
      case let .missingInclude(name, sourceURL):
        return "Metal-Include \(name) wurde für \(sourceURL.lastPathComponent) nicht gefunden."
      case let .recursiveInclude(name):
        return "Rekursives Metal-Include \(name) erkannt."
    }
  }
}

enum RuntimeMetalShaderLoader {
  static func loadSource(named name: String, fileExtension: String = "metal", bundle: Bundle = .main) throws -> String {
    guard let url = resolveResource(named: name, fileExtension: fileExtension, bundle: bundle) else {
      throw RuntimeMetalShaderLoaderError.missingShader("\(name).\(fileExtension)")
    }
    return try expandIncludes(in: url, bundle: bundle, includeStack: [])
  }

  private static func expandIncludes(in url: URL, bundle: Bundle, includeStack: [URL]) throws -> String {
    let standardizedURL = url.standardizedFileURL
    guard !includeStack.contains(standardizedURL) else {
      throw RuntimeMetalShaderLoaderError.recursiveInclude(url.lastPathComponent)
    }

    let source = try String(contentsOf: standardizedURL, encoding: .utf8)
    let baseURL = standardizedURL.deletingLastPathComponent()
    var expanded = ""

    for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
      let lineText = String(line)
      if let includeName = localIncludeName(in: lineText) {
        guard let includeURL = resolveInclude(named: includeName, relativeTo: baseURL, bundle: bundle) else {
          throw RuntimeMetalShaderLoaderError.missingInclude(includeName, standardizedURL)
        }
        expanded += try expandIncludes(in: includeURL, bundle: bundle, includeStack: includeStack + [standardizedURL])
      } else {
        expanded += lineText
        expanded += "\n"
      }
    }

    return expanded
  }

  private static func localIncludeName(in line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    let directives = ["#include", "#import"]
    guard directives.contains(where: { trimmed.hasPrefix($0) }) else {
      return nil
    }
    guard let firstQuote = trimmed.firstIndex(of: "\"") else {
      return nil
    }
    let afterFirstQuote = trimmed.index(after: firstQuote)
    guard let secondQuote = trimmed[afterFirstQuote...].firstIndex(of: "\"") else {
      return nil
    }
    return String(trimmed[afterFirstQuote..<secondQuote])
  }

  private static func resolveInclude(named name: String, relativeTo baseURL: URL, bundle: Bundle) -> URL? {
    let relativeURL = baseURL.appendingPathComponent(name).standardizedFileURL
    if FileManager.default.fileExists(atPath: relativeURL.path) {
      return relativeURL
    }

    let includeURL = URL(fileURLWithPath: name)
    let basename = includeURL.deletingPathExtension().lastPathComponent
    let fileExtension = includeURL.pathExtension

    if let bundleURL = resolveResource(named: basename, fileExtension: fileExtension, bundle: bundle) {
      return bundleURL
    }

    let sourceTreeURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent(name)
      .standardizedFileURL
    if FileManager.default.fileExists(atPath: sourceTreeURL.path) {
      return sourceTreeURL
    }

    return nil
  }

  private static func resolveResource(named name: String, fileExtension: String, bundle: Bundle) -> URL? {
    if let flatURL = bundle.url(forResource: name, withExtension: fileExtension) {
      return flatURL.standardizedFileURL
    }

    if let appSupportURL = bundle.resourceURL?
      .appendingPathComponent("AppSupport")
      .appendingPathComponent("\(name).\(fileExtension)")
      .standardizedFileURL,
      FileManager.default.fileExists(atPath: appSupportURL.path) {
      return appSupportURL
    }

    return nil
  }
}
