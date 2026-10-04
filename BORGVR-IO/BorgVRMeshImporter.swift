#if os(macOS)
import AppKit
import Foundation
import ModelIO
import simd

enum BorgVRMeshImporterError: LocalizedError {
  case unsupportedFile
  case noTriangleGeometry
  case tooManyVertices
  case tooManyIndices
  case invalidGeometry
  case unsupportedIndexType

  var errorDescription: String? {
    switch self {
      case .unsupportedFile:
        return String(localized: "The selected file does not contain a supported mesh.")
      case .noTriangleGeometry:
        return String(localized: "The selected file contains no triangle geometry.")
      case .tooManyVertices:
        return String(localized: "The mesh contains too many vertices.")
      case .tooManyIndices:
        return String(localized: "The mesh contains too many indices.")
      case .invalidGeometry:
        return String(localized: "The mesh contains invalid geometry data.")
      case .unsupportedIndexType:
        return String(localized: "The mesh uses an unsupported index format.")
    }
  }
}

enum BorgVRMeshImporter {
  private struct Vertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var texcoord: SIMD2<Float>
    var color: SIMD3<Float>
  }

  private struct ImportedMesh {
    var id = UUID()
    var name: String
    var vertices: [Vertex]
    var indices: [UInt32]
    var baseColor = SIMD3<Float>(repeating: 1)
    var textureEncoding: UInt8 = 0
    var textureData = Data()
    var boundsMinimum: SIMD3<Float>
    var boundsMaximum: SIMD3<Float>
  }

  static let supportedFilenameExtensions = ["obj", "ply", "stl", "usd", "usda", "usdc"]

  @discardableResult
  static func convert(
    inputURL: URL,
    outputURL: URL,
    name: String? = nil,
    logger: LoggerBase? = nil
  ) throws -> UUID {
    logger?.info("Importing mesh \(inputURL.lastPathComponent). Source coordinates are interpreted as meters.")
    let asset = MDLAsset(url: inputURL)
    asset.loadTextures()
    let objects = asset.childObjects(of: MDLMesh.self)
    guard !objects.isEmpty else { throw BorgVRMeshImporterError.unsupportedFile }

    var allVertices: [Vertex] = []
    var allIndices: [UInt32] = []
    var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
    var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
    var embeddedTexture: (encoding: UInt8, data: Data)?

    for case let mesh as MDLMesh in objects {
      if mesh.vertexAttributeData(
        forAttributeNamed: MDLVertexAttributeNormal,
        as: .float3
      ) == nil {
        mesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.25)
      }
      guard let positions = mesh.vertexAttributeData(
        forAttributeNamed: MDLVertexAttributePosition,
        as: .float3
      ) else { continue }

      let normals = mesh.vertexAttributeData(
        forAttributeNamed: MDLVertexAttributeNormal,
        as: .float3
      )
      let texcoords = mesh.vertexAttributeData(
        forAttributeNamed: MDLVertexAttributeTextureCoordinate,
        as: .float2
      )
      let colors = mesh.vertexAttributeData(
        forAttributeNamed: MDLVertexAttributeColor,
        as: .float4
      )
      let transform = objectTransform(mesh)
      let linearTransform = simd_float3x3(columns: (
        SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
        SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
        SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
      ))
      let normalTransform = simd_transpose(simd_inverse(linearTransform))
      let baseVertex = allVertices.count

      guard baseVertex + mesh.vertexCount <= BorgVRMeshFormat.maximumVertexCount else {
        throw BorgVRMeshImporterError.tooManyVertices
      }
      allVertices.reserveCapacity(baseVertex + mesh.vertexCount)
      for index in 0..<mesh.vertexCount {
        let localPosition = readFloat3(positions, index: index)
        let worldPosition4 = transform * SIMD4<Float>(localPosition, 1)
        let position = SIMD3<Float>(worldPosition4.x, worldPosition4.y, worldPosition4.z)
        let localNormal = normals.map { readFloat3($0, index: index) } ?? SIMD3<Float>(0, 0, 1)
        let transformedNormal = normalTransform * localNormal
        let normal = simd_length_squared(transformedNormal) > 0.000_001
          ? simd_normalize(transformedNormal)
          : SIMD3<Float>(0, 0, 1)
        let texcoord = texcoords.map { readFloat2($0, index: index) } ?? .zero
        let color4 = colors.map { readFloat4($0, index: index) } ?? SIMD4<Float>(repeating: 1)
        let color = simd_clamp(
          SIMD3<Float>(color4.x, color4.y, color4.z),
          SIMD3<Float>(repeating: 0),
          SIMD3<Float>(repeating: 1)
        )
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite,
              normal.x.isFinite, normal.y.isFinite, normal.z.isFinite,
              texcoord.x.isFinite, texcoord.y.isFinite else {
          throw BorgVRMeshImporterError.invalidGeometry
        }
        minimum = simd_min(minimum, position)
        maximum = simd_max(maximum, position)
        allVertices.append(Vertex(
          position: position,
          normal: normal,
          texcoord: texcoord,
          color: color
        ))
      }

      for case let submesh as MDLSubmesh in mesh.submeshes ?? [] {
        let localIndices = try triangleIndices(from: submesh)
        guard allIndices.count + localIndices.count <= BorgVRMeshFormat.maximumIndexCount else {
          throw BorgVRMeshImporterError.tooManyIndices
        }
        for index in localIndices {
          guard Int(index) < mesh.vertexCount,
                baseVertex <= Int(UInt32.max) - Int(index) else {
            throw BorgVRMeshImporterError.invalidGeometry
          }
          allIndices.append(UInt32(baseVertex) + index)
        }
        if embeddedTexture == nil {
          embeddedTexture = textureData(from: submesh.material, relativeTo: inputURL)
        }
      }
    }

    guard !allVertices.isEmpty, allIndices.count >= 3 else {
      throw BorgVRMeshImporterError.noTriangleGeometry
    }
    var imported = ImportedMesh(
      name: sanitizedName(name ?? inputURL.deletingPathExtension().lastPathComponent),
      vertices: allVertices,
      indices: allIndices,
      boundsMinimum: minimum,
      boundsMaximum: maximum
    )
    if let embeddedTexture {
      imported.textureEncoding = embeddedTexture.encoding
      imported.textureData = embeddedTexture.data
    }
    let data = try encode(imported)
    let finalURL = outputURL.pathExtension.lowercased() == BorgVRMeshFormat.fileExtension
      ? outputURL
      : outputURL.appendingPathExtension(BorgVRMeshFormat.fileExtension)
    try data.write(to: finalURL, options: .atomic)
    logger?.info(
      "Stored mesh \(imported.name): \(allVertices.count) vertices, " +
      "\(allIndices.count / 3) triangles, UUID \(imported.id.uuidString)."
    )
    return imported.id
  }

  private static func objectTransform(_ object: MDLObject) -> simd_float4x4 {
    var result = matrix_identity_float4x4
    var current: MDLObject? = object
    while let node = current {
      if let transform = node.transform {
        result = transform.matrix * result
      }
      current = node.parent
    }
    return result
  }

  private static func readFloat2(_ data: MDLVertexAttributeData, index: Int) -> SIMD2<Float> {
    let offset = index * data.stride
    return SIMD2<Float>(
      data.dataStart.loadUnaligned(fromByteOffset: offset, as: Float.self),
      data.dataStart.loadUnaligned(fromByteOffset: offset + 4, as: Float.self)
    )
  }

  private static func readFloat3(_ data: MDLVertexAttributeData, index: Int) -> SIMD3<Float> {
    let offset = index * data.stride
    return SIMD3<Float>(
      data.dataStart.loadUnaligned(fromByteOffset: offset, as: Float.self),
      data.dataStart.loadUnaligned(fromByteOffset: offset + 4, as: Float.self),
      data.dataStart.loadUnaligned(fromByteOffset: offset + 8, as: Float.self)
    )
  }

  private static func readFloat4(_ data: MDLVertexAttributeData, index: Int) -> SIMD4<Float> {
    let offset = index * data.stride
    return SIMD4<Float>(
      data.dataStart.loadUnaligned(fromByteOffset: offset, as: Float.self),
      data.dataStart.loadUnaligned(fromByteOffset: offset + 4, as: Float.self),
      data.dataStart.loadUnaligned(fromByteOffset: offset + 8, as: Float.self),
      data.dataStart.loadUnaligned(fromByteOffset: offset + 12, as: Float.self)
    )
  }

  private static func triangleIndices(from submesh: MDLSubmesh) throws -> [UInt32] {
    let mapped = submesh.indexBuffer.map()
    var source: [UInt32] = []
    source.reserveCapacity(submesh.indexCount)
    for index in 0..<submesh.indexCount {
      switch submesh.indexType {
        case .uInt8:
          source.append(UInt32(mapped.bytes.load(fromByteOffset: index, as: UInt8.self)))
        case .uInt16:
          source.append(UInt32(mapped.bytes.loadUnaligned(
            fromByteOffset: index * MemoryLayout<UInt16>.stride,
            as: UInt16.self
          )))
        case .uInt32:
          source.append(mapped.bytes.loadUnaligned(
            fromByteOffset: index * MemoryLayout<UInt32>.stride,
            as: UInt32.self
          ))
        case .invalid:
          throw BorgVRMeshImporterError.unsupportedIndexType
        @unknown default:
          throw BorgVRMeshImporterError.unsupportedIndexType
      }
    }

    switch submesh.geometryType {
      case .triangles:
        return Array(source.prefix(source.count - source.count % 3))
      case .triangleStrips:
        guard source.count >= 3 else { return [] }
        var result: [UInt32] = []
        result.reserveCapacity((source.count - 2) * 3)
        for index in 0..<(source.count - 2) {
          let triangle = index.isMultiple(of: 2)
            ? [source[index], source[index + 1], source[index + 2]]
            : [source[index + 1], source[index], source[index + 2]]
          if Set(triangle).count == 3 { result.append(contentsOf: triangle) }
        }
        return result
      case .quads:
        var result: [UInt32] = []
        for start in stride(from: 0, to: source.count - source.count % 4, by: 4) {
          result.append(contentsOf: [
            source[start], source[start + 1], source[start + 2],
            source[start], source[start + 2], source[start + 3]
          ])
        }
        return result
      default:
        return []
    }
  }

  private static func textureData(
    from material: MDLMaterial?,
    relativeTo inputURL: URL
  ) -> (encoding: UInt8, data: Data)? {
    guard let property = material?.property(with: .baseColor) else { return nil }
    var textureURL: URL?
    if property.type == .URL {
      textureURL = property.urlValue
    } else if property.type == .string,
              let path = property.stringValue,
              !path.isEmpty {
      textureURL = URL(
        fileURLWithPath: path,
        relativeTo: inputURL.deletingLastPathComponent()
      )
    }
    guard let url = textureURL?.standardizedFileURL,
          let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
    switch url.pathExtension.lowercased() {
      case "png": return (1, data)
      case "jpg", "jpeg": return (2, data)
      default:
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return (1, png)
    }
  }

  private static func sanitizedName(_ name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return String((trimmed.isEmpty ? "Mesh" : trimmed).prefix(BorgVRMeshFormat.maximumNameCharacterCount))
  }

  private static func encode(_ mesh: ImportedMesh) throws -> Data {
    var data = Data()
    appendBytes(Data(BorgVRMeshFormat.magicBytes), to: &data)
    append(mesh.id, to: &data, after: BorgVRMeshFormat.version)
    let nameData = Data(mesh.name.utf8.prefix(BorgVRMeshFormat.maximumNameByteCount))
    append(UInt16(nameData.count), to: &data)
    appendBytes(nameData, to: &data)
    append(mesh.baseColor, to: &data)
    append(mesh.boundsMinimum, to: &data)
    append(mesh.boundsMaximum, to: &data)
    append(UInt32(mesh.vertices.count), to: &data)
    append(UInt32(mesh.indices.count), to: &data)
    append(mesh.textureEncoding, to: &data)
    append(UInt8(0), to: &data)
    append(UInt16(0), to: &data)
    append(UInt32(mesh.textureData.count), to: &data)
    for vertex in mesh.vertices {
      append(vertex.position, to: &data)
      append(vertex.normal, to: &data)
      append(vertex.texcoord.x, to: &data)
      append(vertex.texcoord.y, to: &data)
      append(vertex.color, to: &data)
    }
    for index in mesh.indices { append(index, to: &data) }
    appendBytes(mesh.textureData, to: &data)
    guard data.count <= BorgVRMeshFormat.maximumFileByteCount else {
      throw BorgVRMeshImporterError.invalidGeometry
    }
    return data
  }

  private static func append(_ id: UUID, to data: inout Data, after version: UInt16) {
    append(version, to: &data)
    append(UInt16(0), to: &data)
    var uuid = id.uuid
    withUnsafeBytes(of: &uuid) { data.append(contentsOf: $0) }
  }

  private static func append<T>(_ value: T, to data: inout Data) {
    var value = value
    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
  }

  private static func append(_ value: SIMD3<Float>, to data: inout Data) {
    append(value.x, to: &data)
    append(value.y, to: &data)
    append(value.z, to: &data)
  }

  private static func appendBytes(_ bytes: Data, to data: inout Data) {
    data.append(bytes)
  }
}
#endif
