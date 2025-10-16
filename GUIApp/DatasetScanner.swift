import Foundation
import CryptoKit

struct DatasetInfo {
  let id: String
  let filename: String
  let datasetDescription: String
}

class DatasetScanner {
  private var datasets: [DatasetInfo] = []
  private let directory: String
  private let logger: LoggerBase?

  init(directory: String, logger: LoggerBase? = nil) {
    self.directory = directory
    self.logger = logger
  }

  func loadDatasets() {
    datasets.removeAll()
    let fileManager = FileManager.default
    let directoryURL = URL(fileURLWithPath: directory)

    do {
      let fileURLs = try fileManager.contentsOfDirectory(at: directoryURL,
                                                         includingPropertiesForKeys: nil,
                                                         options: .skipsHiddenFiles)
      for url in fileURLs where url.pathExtension == "data" {
        if let data = try? BORGVRFileData(filename: url.path()) {
          let dataset = DatasetInfo(
            id: data.getMetadata().uniqueID,
            filename: url.path(),
            datasetDescription: data.getMetadata().datasetDescription
          )
          datasets.append(dataset)
          logger?.info("Loaded dataset: \(dataset.filename)")
        } else {
          logger?.warning("Failed to load dataset: \(url.path())")
        }
      }
    } catch {
      logger?.error("Failed to read directory: \(error)")
    }
  }

  func getDatasets() -> [DatasetInfo] {
    return datasets
  }
}

