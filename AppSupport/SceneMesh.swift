import Foundation
import Metal
import MetalKit
import simd
import UniformTypeIdentifiers

extension UTType {
  static let borgVRMesh = UTType(
    exportedAs: "de.uni-due.borgvr.mesh",
    conformingTo: .data
  )
}

enum SceneObjectPrototype: Hashable {
  case sphere
  case mesh(UUID)
}

enum SceneMeshTextureEncoding: UInt8 {
  case none = 0
  case png = 1
  case jpeg = 2
}

struct SceneMeshVertex: Equatable {
  var position: SIMD3<Float>
  var normal: SIMD3<Float>
  var texcoord: SIMD2<Float>
  var color: SIMD3<Float>
}

struct SceneMeshReference: Equatable, Hashable {
  var assetID: UUID
  var name: String
  var assetDescription: String
  var boundsMinimum: SIMD3<Float>
  var boundsMaximum: SIMD3<Float>

  var extentMeters: SIMD3<Float> {
    simd_max(boundsMaximum - boundsMinimum, .zero)
  }

  var maximumExtentMeters: Float {
    let extent = extentMeters
    return max(extent.x, max(extent.y, extent.z))
  }
}

struct SceneMeshAsset: Identifiable, Equatable {
  var id: UUID
  var name: String
  var assetDescription: String
  var vertices: [SceneMeshVertex]
  var indices: [UInt32]
  var baseColor: SIMD3<Float>
  var textureEncoding: SceneMeshTextureEncoding
  var textureData: Data?
  var boundsMinimum: SIMD3<Float>
  var boundsMaximum: SIMD3<Float>

  var reference: SceneMeshReference {
    SceneMeshReference(
      assetID: id,
      name: name,
      assetDescription: assetDescription,
      boundsMinimum: boundsMinimum,
      boundsMaximum: boundsMaximum
    )
  }

  var isRenderable: Bool {
    !vertices.isEmpty && indices.count >= 3 && indices.count.isMultiple(of: 3)
  }
}

struct SceneMeshInstance: Identifiable, Equatable {
  var id: UUID
  var name: String
  var asset: SceneMeshReference
  var translationMeters: SIMD3<Float>
  var rotation: simd_quatf
  var scale: SIMD3<Float>
  var isVisible: Bool

  init(
    id: UUID = UUID(),
    name: String,
    asset: SceneMeshReference,
    translationMeters: SIMD3<Float> = .zero,
    rotation: simd_quatf = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)),
    scale: SIMD3<Float> = .one,
    isVisible: Bool = true
  ) {
    self.id = id
    self.name = name
    self.asset = asset
    self.translationMeters = translationMeters
    self.rotation = rotation
    self.scale = scale
    self.isVisible = isVisible
  }

  var maximumExtentMeters: Float {
    let extent = asset.extentMeters * simd_abs(scale)
    return max(extent.x, max(extent.y, extent.z))
  }

  var transformMeters: simd_float4x4 {
    let safeScale = SIMD3<Float>(
      finiteScale(scale.x),
      finiteScale(scale.y),
      finiteScale(scale.z)
    )
    let safeTranslation = translationMeters.replacingNonFinite(with: 0)
    let safeRotation = rotation.normalizedOrIdentity
    return matrixTranslation(safeTranslation) * simd_float4x4(safeRotation) * matrixScale(safeScale)
  }

  private func finiteScale(_ value: Float) -> Float {
    value.isFinite ? min(1_000_000, max(0.000_001, value)) : 1
  }
}

enum SceneMeshScaleAssessment: Equatable {
  case plausible
  case tooSmall(ratio: Float)
  case tooLarge(ratio: Float)
  case unavailable
}

enum SceneMeshScaleValidator {
  static func assess(
    instance: SceneMeshInstance,
    datasetExtentMeters: SIMD3<Float>?
  ) -> SceneMeshScaleAssessment {
    guard let datasetExtentMeters else { return .unavailable }
    let datasetMaximum = max(
      datasetExtentMeters.x,
      max(datasetExtentMeters.y, datasetExtentMeters.z)
    )
    let meshMaximum = instance.maximumExtentMeters
    guard datasetMaximum.isFinite, datasetMaximum > 0,
          meshMaximum.isFinite, meshMaximum > 0 else {
      return .unavailable
    }
    let ratio = meshMaximum / datasetMaximum
    if ratio < 0.001 { return .tooSmall(ratio: ratio) }
    if ratio > 10 { return .tooLarge(ratio: ratio) }
    return .plausible
  }
}

enum SceneMeshDocumentError: LocalizedError {
  case invalidFormat
  case unsupportedVersion(Int)
  case fileTooLarge
  case invalidGeometry
  case invalidTexture
  case missingAsset(UUID)

  var errorDescription: String? {
    switch self {
      case .invalidFormat:
        return String(localized: "The selected file is not a BorgVR mesh file.")
      case .unsupportedVersion(let version):
        return String(format: String(localized: "Unsupported mesh file version %d."), version)
      case .fileTooLarge:
        return String(localized: "The mesh file exceeds the maximum supported size.")
      case .invalidGeometry:
        return String(localized: "The mesh file contains invalid geometry.")
      case .invalidTexture:
        return String(localized: "The mesh file contains an invalid texture.")
      case .missingAsset(let id):
        return String(format: String(localized: "Mesh asset %@ is not available."), id.uuidString)
    }
  }
}

enum SceneMeshDocument {
  static func encode(_ asset: SceneMeshAsset) throws -> Data {
    guard asset.vertices.count <= BorgVRMeshFormat.maximumVertexCount,
          asset.indices.count <= BorgVRMeshFormat.maximumIndexCount,
          asset.indices.count >= 3,
          asset.indices.count.isMultiple(of: 3),
          asset.indices.allSatisfy({ Int($0) < asset.vertices.count }),
          asset.vertices.allSatisfy(\.isFinite),
          asset.boundsMinimum.isFinite,
          asset.boundsMaximum.isFinite else {
      throw SceneMeshDocumentError.invalidGeometry
    }
    let textureData = asset.textureData ?? Data()
    guard textureData.count <= BorgVRMeshFormat.maximumTextureByteCount,
          (asset.textureEncoding == .none) == textureData.isEmpty else {
      throw SceneMeshDocumentError.invalidTexture
    }

    var writer = MarkerDataWriter()
    writer.writeBytes(Data(BorgVRMeshFormat.magicBytes))
    writer.write(BorgVRMeshFormat.version)
    writer.write(UInt16(0))
    writer.writeUUID(asset.id)
    let nameData = encodedText(
      asset.name,
      maximumCharacterCount: BorgVRMeshFormat.maximumNameCharacterCount,
      maximumByteCount: BorgVRMeshFormat.maximumNameByteCount
    )
    let descriptionData = encodedText(
      asset.assetDescription,
      maximumCharacterCount: BorgVRMeshFormat.maximumDescriptionCharacterCount,
      maximumByteCount: BorgVRMeshFormat.maximumDescriptionByteCount
    )
    writer.write(UInt16(nameData.count))
    writer.write(UInt16(descriptionData.count))
    writer.writeBytes(nameData)
    writer.writeBytes(descriptionData)
    writer.writeSIMD3(asset.baseColor.clamped01)
    writer.writeSIMD3(asset.boundsMinimum)
    writer.writeSIMD3(asset.boundsMaximum)
    writer.write(UInt32(asset.vertices.count))
    writer.write(UInt32(asset.indices.count))
    writer.write(asset.textureEncoding.rawValue)
    writer.write(UInt8(0))
    writer.write(UInt16(0))
    writer.write(UInt32(textureData.count))
    for vertex in asset.vertices {
      writer.writeSIMD3(vertex.position)
      writer.writeSIMD3(vertex.normal)
      writer.write(vertex.texcoord.x)
      writer.write(vertex.texcoord.y)
      writer.writeSIMD3(vertex.color.clamped01)
    }
    for index in asset.indices {
      writer.write(index)
    }
    writer.writeBytes(textureData)
    guard writer.data.count <= BorgVRMeshFormat.maximumFileByteCount else {
      throw SceneMeshDocumentError.fileTooLarge
    }
    return writer.data
  }

  static func decode(from data: Data) throws -> SceneMeshAsset {
    guard data.count <= BorgVRMeshFormat.maximumFileByteCount else {
      throw SceneMeshDocumentError.fileTooLarge
    }
    var reader = MarkerDataReader(data)
    let magic = Data(BorgVRMeshFormat.magicBytes)
    guard try reader.readBytes(count: magic.count) == magic else {
      throw SceneMeshDocumentError.invalidFormat
    }
    let version: UInt16 = try reader.read()
    guard version == BorgVRMeshFormat.version else {
      throw SceneMeshDocumentError.unsupportedVersion(Int(version))
    }
    _ = try reader.read() as UInt16
    let id = try reader.readUUID()
    let nameByteCount = Int(try reader.read() as UInt16)
    let descriptionByteCount = Int(try reader.read() as UInt16)
    guard nameByteCount <= BorgVRMeshFormat.maximumNameByteCount,
          descriptionByteCount <= BorgVRMeshFormat.maximumDescriptionByteCount else {
      throw SceneMeshDocumentError.invalidFormat
    }
    guard let name = String(
            data: try reader.readBytes(count: nameByteCount),
            encoding: .utf8
          ),
          let assetDescription = String(
            data: try reader.readBytes(count: descriptionByteCount),
            encoding: .utf8
          ) else {
      throw SceneMeshDocumentError.invalidFormat
    }
    let baseColor = try reader.readSIMD3()
    let boundsMinimum = try reader.readSIMD3()
    let boundsMaximum = try reader.readSIMD3()
    let vertexCount = Int(try reader.read() as UInt32)
    let indexCount = Int(try reader.read() as UInt32)
    let rawTextureEncoding: UInt8 = try reader.read()
    _ = try reader.read() as UInt8
    _ = try reader.read() as UInt16
    let textureByteCount = Int(try reader.read() as UInt32)
    guard vertexCount > 0,
          vertexCount <= BorgVRMeshFormat.maximumVertexCount,
          indexCount >= 3,
          indexCount <= BorgVRMeshFormat.maximumIndexCount,
          indexCount.isMultiple(of: 3),
          textureByteCount <= BorgVRMeshFormat.maximumTextureByteCount,
          let textureEncoding = SceneMeshTextureEncoding(rawValue: rawTextureEncoding) else {
      throw SceneMeshDocumentError.invalidGeometry
    }

    var vertices: [SceneMeshVertex] = []
    vertices.reserveCapacity(vertexCount)
    for _ in 0..<vertexCount {
      let vertex = SceneMeshVertex(
        position: try reader.readSIMD3(),
        normal: try reader.readSIMD3(),
        texcoord: SIMD2<Float>(try reader.read(), try reader.read()),
        color: try reader.readSIMD3()
      )
      guard vertex.isFinite else { throw SceneMeshDocumentError.invalidGeometry }
      vertices.append(vertex)
    }
    var indices: [UInt32] = []
    indices.reserveCapacity(indexCount)
    for _ in 0..<indexCount {
      let index: UInt32 = try reader.read()
      guard Int(index) < vertexCount else { throw SceneMeshDocumentError.invalidGeometry }
      indices.append(index)
    }
    let textureData = try reader.readBytes(count: textureByteCount)
    guard reader.isAtEnd,
          boundsMinimum.isFinite,
          boundsMaximum.isFinite,
          (textureEncoding == .none) == textureData.isEmpty else {
      throw SceneMeshDocumentError.invalidTexture
    }
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return SceneMeshAsset(
      id: id,
      name: trimmedName.isEmpty ? "Object" : trimmedName,
      assetDescription: assetDescription.trimmingCharacters(in: .whitespacesAndNewlines),
      vertices: vertices,
      indices: indices,
      baseColor: baseColor.clamped01,
      textureEncoding: textureEncoding,
      textureData: textureData.isEmpty ? nil : textureData,
      boundsMinimum: boundsMinimum,
      boundsMaximum: boundsMaximum
    )
  }

  private static func encodedText(
    _ value: String,
    maximumCharacterCount: Int,
    maximumByteCount: Int
  ) -> Data {
    Data(String(value.prefix(maximumCharacterCount)).utf8.prefix(maximumByteCount))
  }
}

enum SceneMeshInstanceCodec {
  static let maximumInstanceCount = 100_000

  static func encode(_ instances: [SceneMeshInstance], to writer: inout MarkerDataWriter) throws {
    guard instances.count <= maximumInstanceCount else {
      throw VolumeMarkerDocumentError.tooManyMarkers
    }
    writer.write(UInt32(instances.count))
    for instance in instances {
      writer.writeUUID(instance.id)
      writer.writeUUID(instance.asset.assetID)
      writer.writeString(instance.name, maxCharacterCount: BorgVRMeshFormat.maximumNameCharacterCount)
      writer.writeString(instance.asset.name, maxCharacterCount: BorgVRMeshFormat.maximumNameCharacterCount)
      writer.writeString(
        instance.asset.assetDescription,
        maxCharacterCount: BorgVRMeshFormat.maximumDescriptionCharacterCount
      )
      writer.writeSIMD3(instance.asset.boundsMinimum)
      writer.writeSIMD3(instance.asset.boundsMaximum)
      writer.writeSIMD3(instance.translationMeters)
      let rotation = instance.rotation.normalizedOrIdentity.vector
      writer.writeSIMD4(rotation)
      writer.writeSIMD3(instance.scale)
      writer.write(instance.isVisible ? UInt8(1) : UInt8(0))
      writer.write(UInt8(0))
      writer.write(UInt16(0))
    }
  }

  static func decode(from reader: inout MarkerDataReader) throws -> [SceneMeshInstance] {
    let count = Int(try reader.read() as UInt32)
    guard count <= maximumInstanceCount else {
      throw VolumeMarkerDocumentError.tooManyMarkers
    }
    var instances: [SceneMeshInstance] = []
    instances.reserveCapacity(count)
    for index in 0..<count {
      let id = try reader.readUUID()
      let assetID = try reader.readUUID()
      let rawName = try reader.readString(maxByteCount: BorgVRMeshFormat.maximumNameByteCount)
      let rawAssetName = try reader.readString(maxByteCount: BorgVRMeshFormat.maximumNameByteCount)
      let assetDescription = try reader.readString(
        maxByteCount: BorgVRMeshFormat.maximumDescriptionByteCount
      )
      let boundsMinimum = try reader.readSIMD3()
      let boundsMaximum = try reader.readSIMD3()
      let translation = try reader.readSIMD3()
      let rotationVector = try reader.readSIMD4()
      let scale = try reader.readSIMD3()
      let flags: UInt8 = try reader.read()
      _ = try reader.read() as UInt8
      _ = try reader.read() as UInt16
      guard boundsMinimum.isFinite, boundsMaximum.isFinite,
            translation.isFinite, rotationVector.isFinite, scale.isFinite else {
        throw SceneMeshDocumentError.invalidGeometry
      }
      let assetName = rawAssetName.trimmingCharacters(in: .whitespacesAndNewlines)
      let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
      instances.append(SceneMeshInstance(
        id: id,
        name: name.isEmpty ? "Object \(index + 1)" : name,
        asset: SceneMeshReference(
          assetID: assetID,
          name: assetName.isEmpty ? "Object" : assetName,
          assetDescription: assetDescription.trimmingCharacters(in: .whitespacesAndNewlines),
          boundsMinimum: boundsMinimum,
          boundsMaximum: boundsMaximum
        ),
        translationMeters: translation,
        rotation: simd_quatf(vector: rotationVector).normalizedOrIdentity,
        scale: SIMD3<Float>(
          max(0.000_001, abs(scale.x)),
          max(0.000_001, abs(scale.y)),
          max(0.000_001, abs(scale.z))
        ),
        isVisible: flags & 1 != 0
      ))
    }
    return instances
  }
}

enum SceneMeshAssetCatalog {
  static let didChangeNotification = Notification.Name("SceneMeshAssetCatalogDidChange")
  static let storageDirectoryName = "Meshes"
  static let remoteMeshByteLimit = 1024 * 1024 * 1024

  static func storageDirectoryURL(logger: LoggerBase? = nil) -> URL? {
    guard let documentsURL = FileManager.default.urls(
      for: .documentDirectory,
      in: .userDomainMask
    ).first else { return nil }
    let directory = documentsURL.appendingPathComponent(storageDirectoryName, isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      return directory
    } catch {
      logger?.warning("Mesh directory unavailable: \(error.localizedDescription)")
      return nil
    }
  }

  @discardableResult
  static func store(_ asset: SceneMeshAsset, logger: LoggerBase? = nil) throws -> URL {
    guard let directory = storageDirectoryURL(logger: logger) else {
      throw CocoaError(.fileNoSuchFile)
    }
    let url = directory
      .appendingPathComponent(asset.id.uuidString)
      .appendingPathExtension(BorgVRMeshFormat.fileExtension)
    try SceneMeshDocument.encode(asset).write(to: url, options: .atomic)
    NotificationCenter.default.post(name: didChangeNotification, object: asset.id)
    return url
  }

  static func load(assetID: UUID, logger: LoggerBase? = nil) -> SceneMeshAsset? {
    guard let directory = storageDirectoryURL(logger: logger) else { return nil }
    let directURL = directory
      .appendingPathComponent(assetID.uuidString)
      .appendingPathExtension(BorgVRMeshFormat.fileExtension)
    if let asset = try? SceneMeshDocument.decode(from: Data(contentsOf: directURL, options: .mappedIfSafe)) {
      return asset
    }
    guard let urls = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil,
      options: .skipsHiddenFiles
    ) else { return nil }
    for url in urls where url.pathExtension.lowercased() == BorgVRMeshFormat.fileExtension {
      if let asset = try? SceneMeshDocument.decode(from: Data(contentsOf: url, options: .mappedIfSafe)),
         asset.id == assetID {
        return asset
      }
    }
    return nil
  }

  static func allAssets(
    additionalDirectoryURLs: [URL] = [],
    logger: LoggerBase? = nil
  ) -> [SceneMeshAsset] {
    var directories = additionalDirectoryURLs
    if let storageDirectory = storageDirectoryURL(logger: logger) {
      directories.insert(storageDirectory, at: 0)
    }
    var visitedDirectories = Set<String>()
    var assets: [UUID: SceneMeshAsset] = [:]
    for directory in directories {
      let canonicalPath = directory.standardizedFileURL.resolvingSymlinksInPath().path
      guard visitedDirectories.insert(canonicalPath).inserted,
            let urls = try? FileManager.default.contentsOfDirectory(
              at: directory,
              includingPropertiesForKeys: nil,
              options: .skipsHiddenFiles
            ) else { continue }
      for url in urls where url.pathExtension.lowercased() == BorgVRMeshFormat.fileExtension {
        do {
          let asset = try SceneMeshDocument.decode(
            from: Data(contentsOf: url, options: .mappedIfSafe)
          )
          assets[asset.id] = asset
        } catch {
          logger?.warning("Ignoring mesh file \(url.lastPathComponent): \(error.localizedDescription)")
        }
      }
    }
    return assets.values.sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  static func serverFiles(logger: LoggerBase? = nil) -> [MeshFileInfo] {
    guard let directory = storageDirectoryURL(logger: logger) else { return [] }
    return allAssets(logger: logger).compactMap { asset in
      let url = directory
        .appendingPathComponent(asset.id.uuidString)
        .appendingPathExtension(BorgVRMeshFormat.fileExtension)
      guard let byteCount = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
        return nil
      }
      return MeshFileInfo(
        id: asset.id,
        filename: url.path,
        name: asset.name,
        meshDescription: asset.assetDescription,
        byteCount: byteCount
      )
    }
  }

  static func storeRemoteMeshes(
    from manager: BORGVRRemoteDataManager,
    byteLimit: Int = remoteMeshByteLimit,
    logger: LoggerBase? = nil
  ) throws -> Int {
    guard manager.supportsMeshes, byteLimit > 0 else { return 0 }
    let remoteMeshes = try manager.requestMeshList()
    var knownIDs = Set(allAssets(logger: logger).map(\.id))
    var transferredBytes = 0
    var storedCount = 0
    for remoteMesh in remoteMeshes where !knownIDs.contains(remoteMesh.id) {
      guard remoteMesh.byteCount <= BorgVRMeshFormat.maximumFileByteCount,
            transferredBytes + remoteMesh.byteCount <= byteLimit else {
        logger?.warning("Mesh sync limit reached before \(remoteMesh.id.uuidString).")
        break
      }
      let data = try manager.requestMesh(id: remoteMesh.id)
      let asset = try SceneMeshDocument.decode(from: data)
      guard asset.id == remoteMesh.id else {
        throw BORGVRRemoteDataManagerError.invalidResponse(
          reason: "Mesh UUID mismatch for \(remoteMesh.id.uuidString)."
        )
      }
      try store(asset, logger: logger)
      transferredBytes += data.count
      storedCount += 1
      knownIDs.insert(asset.id)
    }
    return storedCount
  }
}

struct SceneMeshGPUAsset {
  let vertexBuffer: MTLBuffer
  let indexBuffer: MTLBuffer
  let indexCount: Int
  let texture: MTLTexture?
}

final class SceneMeshGPUCache {
  private var assets: [UUID: SceneMeshGPUAsset] = [:]

  func asset(for mesh: SceneMeshAsset, device: MTLDevice) -> SceneMeshGPUAsset? {
    if let cached = assets[mesh.id] { return cached }
    guard mesh.isRenderable else { return nil }
    let gpuVertices = mesh.vertices.map(SceneMeshGPUVertex.init)
    guard let vertexBuffer = device.makeBuffer(
      bytes: gpuVertices,
      length: MemoryLayout<SceneMeshGPUVertex>.stride * gpuVertices.count,
      options: .storageModeShared
    ), let indexBuffer = device.makeBuffer(
      bytes: mesh.indices,
      length: MemoryLayout<UInt32>.stride * mesh.indices.count,
      options: .storageModeShared
    ) else { return nil }
    vertexBuffer.label = "Mesh \(mesh.name) Vertices"
    indexBuffer.label = "Mesh \(mesh.name) Indices"
    let texture: MTLTexture?
    if let textureData = mesh.textureData {
      texture = try? MTKTextureLoader(device: device).newTexture(
        data: textureData,
        options: [
          .SRGB: true,
          .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)
        ]
      )
    } else {
      texture = nil
    }
    let result = SceneMeshGPUAsset(
      vertexBuffer: vertexBuffer,
      indexBuffer: indexBuffer,
      indexCount: mesh.indices.count,
      texture: texture
    )
    assets[mesh.id] = result
    return result
  }

  func retainOnly(assetIDs: Set<UUID>) {
    assets = assets.filter { assetIDs.contains($0.key) }
  }
}

private struct SceneMeshGPUVertex {
  var position: SIMD3<Float>
  var normal: SIMD3<Float>
  var texcoord: SIMD2<Float>
  var color: SIMD3<Float>

  init(_ vertex: SceneMeshVertex) {
    position = vertex.position
    normal = vertex.normal
    texcoord = vertex.texcoord
    color = vertex.color
  }
}

private extension SceneMeshVertex {
  var isFinite: Bool {
    position.isFinite && normal.isFinite && texcoord.isFinite && color.isFinite
  }
}

private extension SIMD2 where Scalar == Float {
  var isFinite: Bool { x.isFinite && y.isFinite }
}

private extension SIMD3 where Scalar == Float {
  var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
  var clamped01: Self { simd_clamp(self, .zero, .one) }

  func replacingNonFinite(with fallback: Float) -> Self {
    Self(
      x.isFinite ? x : fallback,
      y.isFinite ? y : fallback,
      z.isFinite ? z : fallback
    )
  }
}

private extension SIMD4 where Scalar == Float {
  var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite && w.isFinite }
}

private extension simd_quatf {
  var normalizedOrIdentity: simd_quatf {
    let lengthSquared = simd_length_squared(vector)
    guard vector.isFinite, lengthSquared.isFinite, lengthSquared > 0.000_001 else {
      return simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    }
    return simd_normalize(self)
  }
}
