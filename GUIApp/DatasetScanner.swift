import Foundation
import CryptoKit

struct DatasetInfo {
  let id: Int
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
        if let data = try? BORGVRFileData(filename: url.path()),
            let id = try? genID(url.path()) {
          let dataset = DatasetInfo(
            id: id,
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

  private func genID(_ path: String) throws -> Int {
    return try fastFileHash(from: path)
  }

  func fastFileHash(from path: String) throws -> Int {
    let fileURL = URL(fileURLWithPath: path)
    let chunkSize = 1024 * 1024  // 1 MB

    let fileHandle = try FileHandle(forReadingFrom: fileURL)
    defer { try? fileHandle.close() }

    // Get file size
    let fileSize = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as! UInt64

    // Calculate start offset
    let readSize = min(UInt64(chunkSize), fileSize)
    let startOffset = fileSize - readSize

    // Seek to the start offset
    try fileHandle.seek(toOffset: startOffset)

    // Read data
    let data = try fileHandle.read(upToCount: Int(readSize)) ?? Data()

    // Compute MD5
    let digest = Insecure.MD5.hash(data: data)

    // Use first 8 bytes of digest to create a stable Int (platform-independent)
    let intValue = digest.prefix(8).reduce(0) { acc, byte in
      (acc << 8) | Int(byte)
    } & 0x7FFFFFFFFFFFFFFF

    return intValue
  }

  func getDatasets() -> [DatasetInfo] {
    return datasets
  }
}

