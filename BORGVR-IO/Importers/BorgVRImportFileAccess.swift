import Foundation

/// Retains the original picker URLs and their grants until the import releases them.
final class VolumeImportSourceAccess: @unchecked Sendable {
  let url: URL
  private let accessedURLs: [URL]

  init(url: URL, selectedURLs: [URL]) {
    self.url = url
    accessedURLs = selectedURLs.filter { $0.startAccessingSecurityScopedResource() }
  }

  deinit {
    for url in accessedURLs { url.stopAccessingSecurityScopedResource() }
  }
}

enum BorgVRImportFileAccess {
  enum Error: Swift.Error, LocalizedError {
    case permissionRequired(URL)

    var errorDescription: String? {
      switch self {
        case .permissionRequired(let url):
          return String(format: Bundle.main.localizedString(forKey: "converter_supporting_file_access_required",
            value: "Read access to the referenced file is required: %@", table: nil), url.lastPathComponent)
      }
    }
  }

  static func withReadAccess<T>(primary: URL, supporting: URL, _ body: (URL) throws -> T) throws -> T {
    let access = supporting.startAccessingSecurityScopedResource()
    defer { if access { supporting.stopAccessingSecurityScopedResource() } }
    do {
      let handle = try FileHandle(forReadingFrom: supporting)
      try handle.close()
    } catch {
      guard isPermissionError(error) else { throw error }
      #if os(macOS)
      let presenter = SupportingFilePresenter(primary: primary, supporting: supporting)
      NSFileCoordinator.addFilePresenter(presenter)
      defer { NSFileCoordinator.removeFilePresenter(presenter) }
      let coordinator = NSFileCoordinator(filePresenter: presenter)
      var coordinationError: NSError?
      var result: Result<T, Swift.Error>?
      coordinator.coordinate(readingItemAt: supporting, options: .withoutChanges, error: &coordinationError) { url in
        result = Result {
          // Check the grant before starting expensive conversion work.
          do { let handle = try FileHandle(forReadingFrom: url); try handle.close() }
          catch {
            if isPermissionError(error) { throw Error.permissionRequired(supporting) }
            throw error
          }
          return try body(url)
        }
      }
      if let result { return try result.get() }
      #endif
      throw Error.permissionRequired(supporting)
    }
    return try body(supporting)
  }

  private static func isPermissionError(_ error: Swift.Error) -> Bool {
    var current = error as NSError
    for _ in 0..<8 {
      if current.domain == NSCocoaErrorDomain && current.code == NSFileReadNoPermissionError { return true }
      if current.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(current.code) { return true }
      guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
      current = underlying
    }
    return false
  }
}

#if os(macOS)
private final class SupportingFilePresenter: NSObject, NSFilePresenter {
  let primaryPresentedItemURL: URL?
  let presentedItemURL: URL?
  let presentedItemOperationQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    return queue
  }()

  init(primary: URL, supporting: URL) {
    primaryPresentedItemURL = primary
    presentedItemURL = supporting
    super.init()
  }
}
#endif
