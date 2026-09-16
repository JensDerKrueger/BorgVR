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

struct MarkerFileInfo {
  let id: String
  let filename: String
  let datasetID: String
  let markerDescription: String
  let byteCount: Int
}

private enum DatasetScannerError: Error {
  case invalidTransferFunctionFile
  case invalidMarkerFile
}

class DatasetScanner {
  private static let transferFunctionMagic = [UInt8]("BTF1".utf8)
  private static let transferFunctionFileVersion: UInt32 = 2
  private static let maximumTransferFunctionEntryCount = 1 << 16
  private static let maximumTransferFunctionDescriptionByteCount = 64 * 1024
  private static let maximumMarkerFileByteCount = 64 * 1024 * 1024

  private struct MarkerFileHeader: Decodable {
    let format: String
    let version: Int
    let datasetID: String
  }

  private var datasets: [DatasetInfo] = []
  private var transferFunctions: [TransferFunctionInfo] = []
  private var markerFiles: [MarkerFileInfo] = []
  private let directory: String
  private let logger: LoggerBase?

  init(directory: String, logger: LoggerBase? = nil) {
    self.directory = directory
    self.logger = logger
  }

  func loadDatasets() {
    datasets.removeAll()
    transferFunctions.removeAll()
    markerFiles.removeAll()
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
          case "marker":
            loadMarkerFile(at: url)
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

  func getMarkerFiles() -> [MarkerFileInfo] {
    markerFiles
  }

  static func bundledTransferFunctions(logger: LoggerBase? = nil) -> [TransferFunctionInfo] {
    let urls = Bundle.main.urls(
      forResourcesWithExtension: "tf1d",
      subdirectory: "TransferFunctions"
    ) ?? []
    return transferFunctions(for: urls, logger: logger)
  }

  private func loadDataset(at url: URL) {
    let path = url.path
    if let data = try? BORGVRFileData(filename: path) {
      let dataset = DatasetInfo(
        id: data.getMetadata().uniqueID,
        filename: path,
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
          path
        )
      )
    }
  }

  private func loadTransferFunction(at url: URL) {
    if let transferFunction = DatasetScanner.transferFunctionInfo(at: url, logger: logger) {
      transferFunctions.append(transferFunction)
      logger?.info(
        String(
          format: L(
            "datasetscanner_info_loaded_transfer_function",
            value: "Loaded transfer function: %@ (%@, id %@)",
            comment: "Log: transfer function file successfully loaded"
          ),
          transferFunction.transferFunctionDescription,
          url.lastPathComponent,
          transferFunction.id
        )
      )
    }
  }

  private func loadMarkerFile(at url: URL) {
    do {
      let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
      guard let byteCount = resourceValues.fileSize,
            byteCount > 0,
            byteCount <= Self.maximumMarkerFileByteCount else {
        throw DatasetScannerError.invalidMarkerFile
      }
      let data = try Data(contentsOf: url, options: .mappedIfSafe)
      guard data.count == byteCount,
            data.count <= Self.maximumMarkerFileByteCount else {
        throw DatasetScannerError.invalidMarkerFile
      }
      let header = try JSONDecoder().decode(MarkerFileHeader.self, from: data)
      guard header.format == "BorgVRVolumeMarkers",
            header.version == 1,
            UUID(uuidString: header.datasetID) != nil else {
        throw DatasetScannerError.invalidMarkerFile
      }
      let datasetID = header.datasetID
      let id = Insecure.MD5.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
      markerFiles.append(
        MarkerFileInfo(
          id: id,
          filename: url.path,
          datasetID: datasetID,
          markerDescription: url.deletingPathExtension().lastPathComponent,
          byteCount: data.count
        )
      )
      logger?.info(
        String(
          format: L(
            "datasetscanner_info_loaded_marker_file",
            value: "Loaded marker file: %@ (dataset %@, id %@)",
            comment: "Log: marker file successfully loaded"
          ),
          url.lastPathComponent,
          datasetID,
          id
        )
      )
    } catch {
      logger?.warning(
        String(
          format: L(
            "datasetscanner_warning_failed_load_marker_file",
            value: "Failed to load marker file: %@",
            comment: "Log: marker file could not be loaded"
          ),
          url.path
        )
      )
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
      logger?.warning(
        String(
          format: L(
            "datasetscanner_warning_failed_load_transfer_function",
            value: "Failed to load transfer function file: %@",
            comment: "Log: failed to load transfer function file"
          ),
          url.path
        )
      )
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
