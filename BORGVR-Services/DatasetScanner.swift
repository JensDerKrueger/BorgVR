import Foundation
import CryptoKit

struct DatasetInfo {
  let id: String
  let filename: String
  let datasetDescription: String
}

struct TransferFunctionInfo {
  let id: String
  let filename: String
  let transferFunctionDescription: String
  let byteCount: Int
}

private enum DatasetScannerError: Error {
  case invalidTransferFunctionFile
}

class DatasetScanner {
  private static let transferFunctionMagic = [UInt8]("BTF1".utf8)
  private static let transferFunctionFileVersion: UInt32 = 2
  private static let maximumTransferFunctionEntryCount = 1 << 16
  private static let maximumTransferFunctionDescriptionByteCount = 64 * 1024

  private var datasets: [DatasetInfo] = []
  private var transferFunctions: [TransferFunctionInfo] = []
  private let directory: String
  private let logger: LoggerBase?

  init(directory: String, logger: LoggerBase? = nil) {
    self.directory = directory
    self.logger = logger
  }

  func loadDatasets() {
    datasets.removeAll()
    transferFunctions.removeAll()
    let fileManager = FileManager.default
    let directoryURL = URL(fileURLWithPath: directory)

    do {
      let fileURLs = try fileManager.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: nil,
        options: .skipsHiddenFiles
      )
      for url in fileURLs {
        switch url.pathExtension.lowercased() {
          case "data":
            loadDataset(at: url)
          case "tf1d":
            loadTransferFunction(at: url)
          default:
            break
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

  func getTransferFunctions() -> [TransferFunctionInfo] {
    return transferFunctions
  }

  static func bundledTransferFunctions(logger: LoggerBase? = nil) -> [TransferFunctionInfo] {
    let urls = Bundle.main.urls(
      forResourcesWithExtension: "tf1d",
      subdirectory: "TransferFunctions"
    ) ?? []
    return transferFunctions(for: urls, logger: logger)
  }

  private func loadDataset(at url: URL) {
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

  private func loadTransferFunction(at url: URL) {
    if let transferFunction = DatasetScanner.transferFunctionInfo(at: url, logger: logger) {
      transferFunctions.append(transferFunction)
      logger?.info("Loaded transfer function: \(transferFunction.transferFunctionDescription) (\(url.lastPathComponent), id \(transferFunction.id))")
    }
  }

  private static func displayName(for dataset: DatasetInfo) -> String {
    let description = dataset.datasetDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    if !description.isEmpty {
      return description
    }
    return URL(fileURLWithPath: dataset.filename).deletingPathExtension().lastPathComponent
  }

  private static func parseTransferFunctionData(_ data: Data) throws -> (id: String, description: String) {
    var cursor = 0
    let hasExtendedHeader = data.count >= transferFunctionMagic.count &&
      Array(data.prefix(transferFunctionMagic.count)) == transferFunctionMagic

    let description: String
    let count: UInt32
    if hasExtendedHeader {
      cursor += transferFunctionMagic.count
      let version = try readLittleEndianUInt32(from: data, cursor: &cursor)
      guard version == transferFunctionFileVersion else {
        throw DatasetScannerError.invalidTransferFunctionFile
      }
      let descriptionByteCount = Int(try readLittleEndianUInt32(from: data, cursor: &cursor))
      count = try readLittleEndianUInt32(from: data, cursor: &cursor)
      guard descriptionByteCount <= maximumTransferFunctionDescriptionByteCount else {
        throw DatasetScannerError.invalidTransferFunctionFile
      }
      guard data.count >= cursor + descriptionByteCount else {
        throw DatasetScannerError.invalidTransferFunctionFile
      }
      let descriptionData = data.subdata(in: cursor..<(cursor + descriptionByteCount))
      description = String(data: descriptionData, encoding: .utf8) ?? ""
      cursor += descriptionByteCount
    } else {
      count = try readLittleEndianUInt32(from: data, cursor: &cursor)
      description = ""
    }

    guard count <= UInt32(maximumTransferFunctionEntryCount) else {
      throw DatasetScannerError.invalidTransferFunctionFile
    }
    let rgbaByteCount = Int(count) * MemoryLayout<SIMD4<UInt8>>.size
    guard data.count >= cursor + rgbaByteCount else {
      throw DatasetScannerError.invalidTransferFunctionFile
    }
    let rgbaData = data.subdata(in: cursor..<(cursor + rgbaByteCount))
    let id = Insecure.MD5.hash(data: rgbaData)
      .map { String(format: "%02x", $0) }
      .joined()
    return (id, description)
  }

  private static func transferFunctions(for urls: [URL], logger: LoggerBase?) -> [TransferFunctionInfo] {
    urls.compactMap { transferFunctionInfo(at: $0, logger: logger) }
  }

  private static func transferFunctionInfo(at url: URL, logger: LoggerBase?) -> TransferFunctionInfo? {
    do {
      let fileData = try Data(contentsOf: url)
      let parsed = try parseTransferFunctionData(fileData)
      let fallbackDescription = url.deletingPathExtension().lastPathComponent
      let description = parsed.description.trimmingCharacters(in: .whitespacesAndNewlines)
      return TransferFunctionInfo(
        id: parsed.id,
        filename: url.path,
        transferFunctionDescription: description.isEmpty ? fallbackDescription : description,
        byteCount: fileData.count
      )
    } catch {
      logger?.warning("Failed to load transfer function file: \(url.path)")
      return nil
    }
  }

  private static func readLittleEndianUInt32(from data: Data, cursor: inout Int) throws -> UInt32 {
    guard data.count >= cursor + MemoryLayout<UInt32>.size else {
      throw DatasetScannerError.invalidTransferFunctionFile
    }

    let value = UInt32(data[cursor]) |
      (UInt32(data[cursor + 1]) << 8) |
      (UInt32(data[cursor + 2]) << 16) |
      (UInt32(data[cursor + 3]) << 24)
    cursor += MemoryLayout<UInt32>.size
    return value
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
