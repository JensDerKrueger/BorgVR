import Foundation

struct TransferFunctionCatalogEntry: Identifiable, Equatable {
  enum Source: Equatable {
    case builtIn
    case local
  }

  let id: String
  let description: String
  let url: URL
  let source: Source
  let displayNameOverride: String?

  init(
    id: String,
    description: String,
    url: URL,
    source: Source,
    displayNameOverride: String? = nil
  ) {
    self.id = id
    self.description = description
    self.url = url
    self.source = source
    self.displayNameOverride = displayNameOverride
  }

  var displayName: String {
    if let displayNameOverride {
      return displayNameOverride
    }
    if !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return description
    }
    return url.deletingPathExtension().lastPathComponent
  }
}

enum TransferFunctionCatalog {
  static let storageDirectoryName = "TransferFunctions"
  static let bundledSubdirectory = "TransferFunctions"
  static let remoteTransferFunctionByteLimit = 32 * 1024 * 1024

  static func storageDirectoryURL(logger: LoggerBase? = nil) -> URL? {
    guard let documentsURL = FileManager.default.urls(
      for: .documentDirectory,
      in: .userDomainMask
    ).first else {
      return nil
    }

    let directoryURL = documentsURL.appendingPathComponent(storageDirectoryName, isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
      return directoryURL
    } catch {
      logger?.warning("Transfer function directory unavailable: \(error.localizedDescription)")
      return nil
    }
  }

  static func entries(
    additionalDirectoryURLs: [URL] = [],
    datasetTransferFunctionURL: URL? = nil,
    logger: LoggerBase? = nil
  ) -> [TransferFunctionCatalogEntry] {
    let datasetTransferFunctionURL = datasetTransferFunctionURL?.standardizedFileURL
    var entries: [TransferFunctionCatalogEntry] = []
    entries.append(contentsOf: bundledEntries(logger: logger))
    entries.append(contentsOf: storedEntries(
      datasetTransferFunctionURL: datasetTransferFunctionURL,
      logger: logger
    ))
    entries.append(contentsOf: directoryEntries(
      for: additionalDirectoryURLs,
      datasetTransferFunctionURL: datasetTransferFunctionURL,
      logger: logger
    ))

    var entriesByID: [String: TransferFunctionCatalogEntry] = [:]
    for entry in entries {
      if let current = entriesByID[entry.id],
         current.displayNameOverride != nil || entry.displayNameOverride == nil {
        continue
      }
      entriesByID[entry.id] = entry
    }
    return entries
      .compactMap { entriesByID.removeValue(forKey: $0.id) }
      .sorted { lhs, rhs in
        lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
      }
  }

  static func storeRemoteTransferFunctions(
    from manager: BORGVRRemoteDataManager,
    byteLimit: Int = remoteTransferFunctionByteLimit,
    logger: LoggerBase? = nil
  ) throws -> Int {
    guard byteLimit > 0,
          let directoryURL = storageDirectoryURL(logger: logger) else {
      return 0
    }

    let remoteTransferFunctions = try manager.requestTransferFunctionList()
    var transferredBytes = 0
    var storedCount = 0

    for remoteTransferFunction in remoteTransferFunctions {
      let targetURL = directoryURL
        .appendingPathComponent(remoteTransferFunction.id)
        .appendingPathExtension("tf1d")

      if FileManager.default.fileExists(atPath: targetURL.path) {
        continue
      }

      guard transferredBytes + remoteTransferFunction.byteCount <= byteLimit else {
        logger?.warning("Transfer function sync limit reached before \(remoteTransferFunction.id).")
        break
      }

      let data = try manager.requestTransferFunction(id: remoteTransferFunction.id)
      let actualId = try TransferFunction1D.identifier(for: data)
      guard actualId == remoteTransferFunction.id else {
        throw BORGVRRemoteDataManagerError.invalidResponse(
          reason: "Transfer function ID mismatch for \(remoteTransferFunction.id)."
        )
      }

      try data.write(to: targetURL, options: .atomic)
      transferredBytes += data.count
      storedCount += 1
    }

    return storedCount
  }

  @discardableResult
  static func store(
    transferFunction: TransferFunction1D,
    description: String,
    logger: LoggerBase? = nil
  ) throws -> URL {
    guard let directoryURL = storageDirectoryURL(logger: logger) else {
      throw CocoaError(.fileNoSuchFile)
    }

    let data = transferFunction.serialize(description: description)
    let id = try TransferFunction1D.identifier(for: data)
    let targetURL = directoryURL
      .appendingPathComponent(id)
      .appendingPathExtension("tf1d")
    try data.write(to: targetURL, options: .atomic)
    return targetURL
  }

  private static func bundledEntries(logger: LoggerBase?) -> [TransferFunctionCatalogEntry] {
    let urls = Bundle.main.urls(
      forResourcesWithExtension: "tf1d",
      subdirectory: bundledSubdirectory
    ) ?? []
    return entries(for: urls, source: .builtIn, logger: logger)
  }

  private static func storedEntries(
    datasetTransferFunctionURL: URL?,
    logger: LoggerBase?
  ) -> [TransferFunctionCatalogEntry] {
    guard let directoryURL = storageDirectoryURL(logger: logger),
          let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
          ) else {
      return []
    }
    return entries(
      for: urls.filter { $0.pathExtension.lowercased() == "tf1d" },
      source: .local,
      logger: logger
    ).compactMap {
      catalogEntry($0, datasetTransferFunctionURL: datasetTransferFunctionURL)
    }
  }

  private static func directoryEntries(
    for directoryURLs: [URL],
    datasetTransferFunctionURL: URL?,
    logger: LoggerBase?
  ) -> [TransferFunctionCatalogEntry] {
    let fileManager = FileManager.default
    let urls = directoryURLs.flatMap { directoryURL in
      let isAccessing = directoryURL.startAccessingSecurityScopedResource()
      defer {
        if isAccessing {
          directoryURL.stopAccessingSecurityScopedResource()
        }
      }

      return (try? fileManager.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: nil
      )) ?? []
    }

    return entries(
      for: urls.filter { $0.pathExtension.lowercased() == "tf1d" },
      source: .local,
      logger: logger
    ).compactMap {
      catalogEntry($0, datasetTransferFunctionURL: datasetTransferFunctionURL)
    }
  }

  private static func entries(
    for urls: [URL],
    source: TransferFunctionCatalogEntry.Source,
    logger: LoggerBase?
  ) -> [TransferFunctionCatalogEntry] {
    urls.compactMap { url in
      do {
        let data = try Data(contentsOf: url)
        return TransferFunctionCatalogEntry(
          id: try TransferFunction1D.identifier(for: data),
          description: try TransferFunction1D.fileDescription(from: data),
          url: url,
          source: source
        )
      } catch {
        logger?.warning("Ignoring transfer function \(url.lastPathComponent): \(error.localizedDescription)")
        return nil
      }
    }
  }

  private static func catalogEntry(
    _ entry: TransferFunctionCatalogEntry,
    datasetTransferFunctionURL: URL?
  ) -> TransferFunctionCatalogEntry? {
    if matchesDatasetTransferFunctionURL(entry.url, datasetTransferFunctionURL) {
      return TransferFunctionCatalogEntry(
        id: entry.id,
        description: entry.description,
        url: entry.url,
        source: entry.source,
        displayNameOverride: String(localized: "tf_catalog_dataset_saved")
      )
    }

    if isDatasetAutosave(entry) {
      return nil
    }

    return entry
  }

  private static func isDatasetAutosave(_ entry: TransferFunctionCatalogEntry) -> Bool {
    entry.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
      UUID(uuidString: entry.url.deletingPathExtension().lastPathComponent) != nil
  }

  private static func matchesDatasetTransferFunctionURL(_ lhs: URL, _ rhs: URL?) -> Bool {
    guard let rhs else { return false }
    return lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
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
