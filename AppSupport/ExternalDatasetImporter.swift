import Foundation

enum ExternalDatasetImportError: LocalizedError {
  case unsupportedExtension
  case destinationUnavailable

  var errorDescription: String? {
    switch self {
      case .unsupportedExtension:
        return String(localized: "external_dataset_error_extension")
      case .destinationUnavailable:
        return String(localized: "external_dataset_error_destination")
    }
  }
}

enum ExternalDatasetImporter {
  static func importDataset(
    from sourceURL: URL,
    into destinationDirectory: URL,
    logger: GUILogger
  ) throws -> AppModel.DatasetEntry {
    guard sourceURL.pathExtension.lowercased() == "data" else {
      throw ExternalDatasetImportError.unsupportedExtension
    }

    let sourceAccess = sourceURL.startAccessingSecurityScopedResource()
    defer {
      if sourceAccess {
        sourceURL.stopAccessingSecurityScopedResource()
      }
    }

    let destinationAccess = destinationDirectory.startAccessingSecurityScopedResource()
    defer {
      if destinationAccess {
        destinationDirectory.stopAccessingSecurityScopedResource()
      }
    }

    let fileManager = FileManager.default
    try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

    let destinationURL = try copiedDatasetURL(
      for: sourceURL,
      in: destinationDirectory,
      fileManager: fileManager
    )
    let metadata = try BORGVRMetaData(url: destinationURL)
    let description = metadata.datasetDescription.isEmpty
      ? destinationURL.deletingPathExtension().lastPathComponent
      : metadata.datasetDescription

    logger.info(
      String(
        format: String(localized: "external_dataset_imported_format"),
        destinationURL.lastPathComponent
      )
    )

    return AppModel.DatasetEntry(
      identifier: destinationURL.path,
      description: description,
      source: .local,
      uniqueId: metadata.uniqueID,
      metadataSummary: metadata.borgvrSummaryText
    )
  }

  private static func copiedDatasetURL(
    for sourceURL: URL,
    in destinationDirectory: URL,
    fileManager: FileManager
  ) throws -> URL {
    let standardizedSource = sourceURL.standardizedFileURL
    let initialDestination = destinationDirectory
      .appendingPathComponent(sourceURL.lastPathComponent)
      .standardizedFileURL

    if standardizedSource.path == initialDestination.path {
      return initialDestination
    }

    let destinationURL = uniqueDestinationURL(
      for: initialDestination,
      fileManager: fileManager
    )
    try fileManager.copyItem(at: sourceURL, to: destinationURL)
    return destinationURL
  }

  private static func uniqueDestinationURL(for url: URL, fileManager: FileManager) -> URL {
    guard fileManager.fileExists(atPath: url.path) else { return url }

    let directory = url.deletingLastPathComponent()
    let baseName = url.deletingPathExtension().lastPathComponent
    let pathExtension = url.pathExtension

    var index = 2
    while true {
      let candidate = directory
        .appendingPathComponent("\(baseName)-\(index)")
        .appendingPathExtension(pathExtension)
      if !fileManager.fileExists(atPath: candidate.path) {
        return candidate
      }
      index += 1
    }
  }
}

extension BORGVRMetaData {
  var borgvrSummaryText: String {
    let bitsPerComponent = bytesPerComponent * 8
    let channelText = componentCount == 1
      ? String(localized: "1 Kanal")
      : String(format: String(localized: "metadata_channel_count_format"), componentCount)
    let compressionText = compression
      ? String(localized: "komprimiert")
      : String(localized: "unkomprimiert")
    let lodText = levelMetadata.count == 1
      ? String(localized: "1 LOD")
      : String(format: String(localized: "metadata_lod_count_format"), levelMetadata.count)

    return "\(width) x \(height) x \(depth) - " +
      "\(bitsPerComponent)-bit, \(channelText) - " +
      "\(String(localized: "Brick")) \(brickSize) - \(lodText) - " +
      "\(compressionText) - \(String(localized: "Werte")) \(minValue)...\(maxValue)"
  }
}
