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
      let fileURLs = try fileManager.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: nil,
        options: .skipsHiddenFiles
      )
      for url in fileURLs where url.pathExtension == "data" {
        if let data = try? BORGVRFileData(filename: url.path()) {
          let dataset = DatasetInfo(
            id: data.getMetadata().uniqueID,
            filename: url.path(),
            datasetDescription: data.getMetadata().datasetDescription
          )
          datasets.append(dataset)
          let datasetName = DatasetScanner.displayName(for: dataset)
          let filename = url.lastPathComponent
          logger?.info(
            String(
              format: L(
                "datasetscanner_info_loaded_dataset",
                value: "Loaded dataset: %@ (%@, id %@)",
                comment: "Log: dataset file successfully loaded"
              ),
              datasetName,
              filename,
              dataset.id
            )
          )
        } else {
          logger?.warning(
            String(
              format: L(
                "datasetscanner_warning_failed_load_dataset",
                value: "Failed to load dataset file: %@",
                comment: "Log: failed to load dataset file"
              ),
              url.path()
            )
          )
        }
      }
    } catch {
      logger?.error(
        L(
          "datasetscanner_error_failed_read_directory",
          value: "Failed to read directory:",
          comment: "Log: failed to read dataset directory"
        ) + " \(error)"
      )
    }
  }

  func getDatasets() -> [DatasetInfo] {
    return datasets
  }

  private static func displayName(for dataset: DatasetInfo) -> String {
    let description = dataset.datasetDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    if !description.isEmpty {
      return description
    }
    return URL(fileURLWithPath: dataset.filename).deletingPathExtension().lastPathComponent
  }
}

// MARK: - Localized string helper

private func L(_ key: String, value: String, comment: String = "") -> String {
  NSLocalizedString(key, tableName: nil, bundle: .main, value: value, comment: comment)
}

/*
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of Duisburg-
 Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of this
 software and associated documentation files (the "Software"), to deal in the Software
 without restriction, including without limitation the rights to use, copy, modify,
 merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 permit persons to whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included in all copies
 or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
 CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR
 THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
