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

/*
 Copyright (c) 2025 Computer Graphics and Visualization Group, University of Duisburg-
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
