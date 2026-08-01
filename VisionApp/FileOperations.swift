func copyFile(from sourceURL: URL, toDir destinationDirURL: URL, logger: GUILogger?) -> URL? {
  let destinationURL = destinationDirURL.appendingPathComponent(sourceURL.lastPathComponent)
  let fileManager = FileManager.default
  do {
    let destinationDirectory = destinationURL.deletingLastPathComponent()
    if !fileManager.fileExists(atPath: destinationDirectory.path) {
      try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
    }
    if fileManager.fileExists(atPath: destinationURL.path) {
      try fileManager.removeItem(at: destinationURL)
    }
    try fileManager.copyItem(at: sourceURL, to: destinationURL)
    logger?.info("File copied successfully")
    return destinationURL
  } catch {
    logger?.error("Error copying file: \(error.localizedDescription)")
    return nil
  }
}

func findlocalFile(id : String) -> URL? {
  let localDatasets = listLocalDatasets()
  if let match = localDatasets.first(where: { $0.0 == id }) {
    return match.1
  }
  return nil
}

private func listLocalDatasets() -> [(String, URL, RuntimeAppModel.DatasetSource)] {
  var datasets: [(String, URL, RuntimeAppModel.DatasetSource)] = []

  if let datasetURLs = Bundle.main.urls(forResourcesWithExtension: "data", subdirectory: nil) {
    for url in datasetURLs {
      if let data = try? BORGVRMetaData(url: url) {
        datasets.append((
          data.uniqueID,
          url,
          .builtIn
        ))
      }
    }
  }

  let fileManager = FileManager.default
  if let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
    if let files = try? fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil) {
      let datasetURLs = files.filter { $0.pathExtension.lowercased() == "data" }
      for url in datasetURLs {
        if let data = try? BORGVRMetaData(url: url) {
          datasets.append((
            data.uniqueID,
            url,
            .local
          ))
        }
      }
    }
  }

  return datasets
}
