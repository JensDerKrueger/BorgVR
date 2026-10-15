import Foundation
import simd

enum BorgVRMCPDefaults {
  static let port = 8765
  static let enabled = false
  static let allowRemoteConnections = false
  static let accessToken = ""
}

struct BorgVRMCPConfiguration: Equatable, Sendable {
  var enabled: Bool
  var port: Int
  var allowRemoteConnections: Bool
  var accessToken: String

  var normalizedPort: UInt16 {
    UInt16(clamping: min(max(port, 1), 65_535))
  }
}

struct BorgVRMCPDatasetState: Codable, Sendable {
  var id: String
  var description: String
  var dimensions: [Int]?
  var physicalExtentMeters: [Float]?
}

struct BorgVRMCPDatasetMetadata: Codable, Sendable {
  var longDescription: String
  var dimensions: [Int]
  var voxelSpacingMeters: [Float]
  var physicalExtentMeters: [Float]
  var componentCount: Int
  var bytesPerComponent: Int
  var bitsPerComponent: Int
  var valueRange: [Int]
  var brickSize: Int
  var overlap: Int
  var levelCount: Int
  var brickCount: Int
  var compressed: Bool

  init(_ metadata: BORGVRMetaData) {
    longDescription = metadata.metaDescription
    dimensions = [metadata.width, metadata.height, metadata.depth]
    voxelSpacingMeters = [
      metadata.voxelSpacingX,
      metadata.voxelSpacingY,
      metadata.voxelSpacingZ
    ]
    physicalExtentMeters = metadata.physicalExtentMeters.mcpArray
    componentCount = metadata.componentCount
    bytesPerComponent = metadata.bytesPerComponent
    bitsPerComponent = metadata.bytesPerComponent * 8
    valueRange = [metadata.minValue, metadata.maxValue]
    brickSize = metadata.brickSize
    overlap = metadata.overlap
    levelCount = metadata.levelMetadata.count
    brickCount = metadata.brickMetadata.count
    compressed = metadata.compression
  }
}

struct BorgVRMCPDatasetSource: Codable, Equatable, Sendable {
  var kind: String
  var address: String?
  var port: Int?
  var passwordProtected: Bool
}

struct BorgVRMCPDatasetCatalogEntry: Codable, Sendable {
  var id: String
  var description: String
  var metadata: BorgVRMCPDatasetMetadata?
  var metadataError: String?
  var sources: [BorgVRMCPDatasetSource]
}

enum BorgVRMCPDatasetLocation: Sendable {
  case local(URL)
  case builtIn(URL)
  case remote(address: String, port: Int, password: String)

  var source: BorgVRMCPDatasetSource {
    switch self {
      case .local:
        return BorgVRMCPDatasetSource(
          kind: "local", address: nil, port: nil, passwordProtected: false
        )
      case .builtIn:
        return BorgVRMCPDatasetSource(
          kind: "built_in", address: nil, port: nil, passwordProtected: false
        )
      case .remote(let address, let port, let password):
        return BorgVRMCPDatasetSource(
          kind: "remote",
          address: address,
          port: port,
          passwordProtected: !password.isEmpty
        )
    }
  }

  fileprivate var priority: Int {
    switch self {
      case .local: 0
      case .builtIn: 1
      case .remote: 2
    }
  }
}

struct BorgVRMCPDatasetRecord: Sendable {
  var catalogEntry: BorgVRMCPDatasetCatalogEntry
  var preferredLocation: BorgVRMCPDatasetLocation
}

enum BorgVRMCPDatasetCatalog {
  static func load(
    localDirectory: URL?,
    servers: [StoredServer],
    timeout: TimeInterval
  ) async -> [BorgVRMCPDatasetRecord] {
    await Task.detached(priority: .userInitiated) {
      var records: [String: BorgVRMCPDatasetRecord] = [:]

      if let localDirectory {
        let urls = (try? FileManager.default.contentsOfDirectory(
          at: localDirectory,
          includingPropertiesForKeys: nil
        )) ?? []
        for url in urls where url.pathExtension.lowercased() == "data" {
          addLocalDataset(at: url, location: .local(url), to: &records)
        }
      }

      for url in Bundle.main.urls(forResourcesWithExtension: "data", subdirectory: nil) ?? [] {
        addLocalDataset(at: url, location: .builtIn(url), to: &records)
      }

      for server in servers where !server.address.isEmpty {
        let location = BorgVRMCPDatasetLocation.remote(
          address: server.address,
          port: server.port,
          password: server.password
        )
        do {
          let manager = BORGVRRemoteDataManager(
            host: server.address,
            port: UInt16(clamping: server.port),
            authSecret: server.password,
            logger: nil
          )
          try manager.connect(timeout: timeout)
          let datasets = try manager.requestDatasetList()
          for dataset in datasets {
            if var record = records[dataset.id] {
              appendSource(location.source, to: &record.catalogEntry.sources)
              if location.priority < record.preferredLocation.priority {
                record.preferredLocation = location
              }
              records[dataset.id] = record
              continue
            }

            do {
              let metadataManager = BORGVRRemoteDataManager(
                host: server.address,
                port: UInt16(clamping: server.port),
                authSecret: server.password,
                logger: nil
              )
              try metadataManager.connect(timeout: timeout)
              let remoteData = try metadataManager.openDataset(
                datasetID: dataset.id,
                timeout: timeout
              )
              let metadata = remoteData.getMetadata()
              records[dataset.id] = BorgVRMCPDatasetRecord(
                catalogEntry: BorgVRMCPDatasetCatalogEntry(
                  id: dataset.id,
                  description: dataset.description,
                  metadata: BorgVRMCPDatasetMetadata(metadata),
                  metadataError: nil,
                  sources: [location.source]
                ),
                preferredLocation: location
              )
            } catch {
              records[dataset.id] = BorgVRMCPDatasetRecord(
                catalogEntry: BorgVRMCPDatasetCatalogEntry(
                  id: dataset.id,
                  description: dataset.description,
                  metadata: nil,
                  metadataError: error.localizedDescription,
                  sources: [location.source]
                ),
                preferredLocation: location
              )
            }
          }
        } catch {
          continue
        }
      }

      return records.values.sorted {
        $0.catalogEntry.description.localizedCaseInsensitiveCompare(
          $1.catalogEntry.description
        ) == .orderedAscending
      }
    }.value
  }

  private static func addLocalDataset(
    at url: URL,
    location: BorgVRMCPDatasetLocation,
    to records: inout [String: BorgVRMCPDatasetRecord]
  ) {
    guard let metadata = try? BORGVRMetaData(url: url) else { return }
    let source = location.source
    if var record = records[metadata.uniqueID] {
      appendSource(source, to: &record.catalogEntry.sources)
      if location.priority < record.preferredLocation.priority {
        record.preferredLocation = location
      }
      records[metadata.uniqueID] = record
      return
    }
    records[metadata.uniqueID] = BorgVRMCPDatasetRecord(
      catalogEntry: BorgVRMCPDatasetCatalogEntry(
        id: metadata.uniqueID,
        description: metadata.datasetDescription,
        metadata: BorgVRMCPDatasetMetadata(metadata),
        metadataError: nil,
        sources: [source]
      ),
      preferredLocation: location
    )
  }

  private static func appendSource(
    _ source: BorgVRMCPDatasetSource,
    to sources: inout [BorgVRMCPDatasetSource]
  ) {
    guard !sources.contains(source) else { return }
    sources.append(source)
  }
}

struct BorgVRMCPTransformState: Codable, Sendable {
  var rotation: [Float]
  var translation: [Float]
  var scale: [Float]
}

struct BorgVRMCPLightingState: Codable, Sendable {
  var direction: [Float]
  var ambient: [Float]
  var diffuse: [Float]
  var specular: [Float]
}

struct BorgVRMCPApplicationState: Codable, Sendable {
  var applicationVersion: String
  var platform: String
  var dataset: BorgVRMCPDatasetState?
  var rendererReady: Bool
  var completedFrame: UInt64
  var renderMode: String
  var normalizedIsoValue: Float
  var transform: BorgVRMCPTransformState
  var clipMinimum: [Float]
  var clipMaximum: [Float]
  var lighting: BorgVRMCPLightingState
  var objectCount: Int
  var measurementCount: Int
}

struct BorgVRMCPImage: Sendable {
  var pngData: Data
  var width: Int
  var height: Int
  var renderedFrame: UInt64
}

enum BorgVRMCPResetScope: String, CaseIterable, Sendable {
  case all
  case transform
  case clipping
  case transferFunction = "transfer_function"
  case lighting
}

enum BorgVRMCPCommandError: LocalizedError {
  case invalidArgument(String)
  case noDataset
  case rendererUnavailable
  case screenshotUnavailable
  case timeout
  case unsupported(String)
  case datasetNotFound(String)

  var errorDescription: String? {
    switch self {
      case .invalidArgument(let message): return message
      case .noDataset: return "No dataset is open."
      case .rendererUnavailable: return "The renderer is not available."
      case .screenshotUnavailable: return "Screenshot capture is not available."
      case .timeout: return "The renderer did not finish before the timeout."
      case .unsupported(let message): return message
      case .datasetNotFound(let id): return "No dataset with ID '\(id)' was found."
    }
  }
}

final class BorgVRMCPContinuationGate<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Error>?

  init(_ continuation: CheckedContinuation<Value, Error>) {
    self.continuation = continuation
  }

  func resume(with result: Result<Value, Error>) {
    lock.lock()
    let continuation = continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(with: result)
  }
}

@MainActor
protocol BorgVRMCPCommandService: AnyObject {
  func listDatasets() async throws -> [BorgVRMCPDatasetCatalogEntry]
  func openDataset(id: String) async throws
  func closeDataset() async throws
  func applicationState() -> BorgVRMCPApplicationState
  func setRenderMode(_ mode: String) throws
  func setTransform(
    rotation: SIMD4<Float>?,
    translation: SIMD3<Float>?,
    scale: SIMD3<Float>?
  ) throws
  func rotate(axis: SIMD3<Float>, degrees: Float) throws
  func setNormalizedIsoValue(_ value: Float) throws
  func setClipping(minimum: SIMD3<Float>, maximum: SIMD3<Float>) throws
  func setLighting(
    direction: SIMD3<Float>?,
    ambient: SIMD3<Float>?,
    diffuse: SIMD3<Float>?,
    specular: SIMD3<Float>?
  ) throws
  func reset(_ scope: BorgVRMCPResetScope) throws
  func waitUntilRendered(after frame: UInt64, timeout: TimeInterval) async throws
  func captureScreenshot() async throws -> BorgVRMCPImage
}

extension SIMD3 where Scalar == Float {
  var mcpArray: [Float] { [x, y, z] }
}

extension SIMD4 where Scalar == Float {
  var mcpArray: [Float] { [x, y, z, w] }
}
