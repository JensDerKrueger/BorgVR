import Foundation

/// Recover a confirmed replacement that FileDocument export reported as a duplicate.
enum CoordinatedFileExportRecovery {
  static func finish(_ result: Result<URL, Error>, data: () throws -> Data) throws {
    guard case .failure(let error) = result else { return }
    guard containsDuplicate(error), let destination = destinationURL(error) else { throw error }
    let contents = try data()
    let accessed = destination.startAccessingSecurityScopedResource()
    defer { if accessed { destination.stopAccessingSecurityScopedResource() } }
    var coordinationError: NSError?
    var writeError: Error?
    NSFileCoordinator().coordinate(
      writingItemAt: destination, options: .forReplacing, error: &coordinationError
    ) { url in
      do { try contents.write(to: url, options: .atomic) } catch { writeError = error }
    }
    if let coordinationError { throw coordinationError }
    if let writeError { throw writeError }
  }

  private static func underlying(_ error: NSError) -> [Error] {
    var errors = error.userInfo[NSMultipleUnderlyingErrorsKey] as? [Error] ?? []
    if let error = error.userInfo[NSUnderlyingErrorKey] as? Error { errors.append(error) }
    return errors
  }
  private static func containsDuplicate(_ error: Error, depth: Int = 0) -> Bool {
    guard depth < 16 else { return false }
    let error = error as NSError
    return (error.domain == NSOSStatusErrorDomain && error.code == -48)
      || underlying(error).contains { containsDuplicate($0, depth: depth + 1) }
  }
  private static func destinationURL(_ value: Error, depth: Int = 0) -> URL? {
    guard depth < 16 else { return nil }
    let error = value as NSError
    for key in ["NSFileNewItemLocationKey", "NSDestinationURL", "NSDestinationFilePath"] {
      if let url = error.userInfo[key] as? URL, url.isFileURL { return url }
      if let path = error.userInfo[key] as? String, path.hasPrefix("/") {
        return URL(fileURLWithPath: path)
      }
    }
    return underlying(error).lazy.compactMap { destinationURL($0, depth: depth + 1) }.first
  }
}
