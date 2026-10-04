#if os(macOS)
import Foundation

enum BorgVRMeshOBJExporterError: LocalizedError {
  case invalidFormat
  case unsupportedVersion(Int)
  case invalidGeometry
  case invalidTexture

  var errorDescription: String? {
    switch self {
      case .invalidFormat:
        return String(localized: "The selected file is not a BorgVR mesh file.")
      case .unsupportedVersion(let version):
        return String(format: String(localized: "Unsupported mesh file version %d."), version)
      case .invalidGeometry:
        return String(localized: "The mesh file contains invalid geometry.")
      case .invalidTexture:
        return String(localized: "The mesh file contains an invalid texture.")
    }
  }
}

enum BorgVRMeshOBJExporter {
  private enum TextureEncoding: UInt8 {
    case none = 0
    case png = 1
    case jpeg = 2
  }

  private struct Vertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var texcoord: SIMD2<Float>
    var color: SIMD3<Float>

    var isFinite: Bool {
      position.isFinite && normal.isFinite && texcoord.isFinite && color.isFinite
    }
  }

  private struct Mesh {
    var name: String
    var vertices: [Vertex]
    var indices: [UInt32]
    var baseColor: SIMD3<Float>
    var textureEncoding: TextureEncoding
    var textureData: Data?
  }

  static func validate(inputURL: URL) throws {
    _ = try decode(Data(contentsOf: inputURL, options: .mappedIfSafe))
  }

  @discardableResult
  static func export(
    inputURL: URL,
    outputURL: URL,
    logger: LoggerBase? = nil
  ) throws -> URL {
    let asset = try decode(Data(contentsOf: inputURL, options: .mappedIfSafe))
    let outputURL = outputURL.pathExtension.lowercased() == "obj"
      ? outputURL
      : outputURL.appendingPathExtension("obj")
    let directory = outputURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let sidecarBaseName = sanitizedFileStem(outputURL.deletingPathExtension().lastPathComponent)
    let materialURL = directory.appendingPathComponent(sidecarBaseName).appendingPathExtension("mtl")
    let textureURL = textureURL(for: asset, directory: directory, baseName: sidecarBaseName)
    let temporaryURL = directory
      .appendingPathComponent(".\(UUID().uuidString)")
      .appendingPathExtension("obj.tmp")
    defer { try? FileManager.default.removeItem(at: temporaryURL) }

    logger?.info("Exporting \(inputURL.lastPathComponent) as OBJ.")
    var writer = try BufferedTextFileWriter(url: temporaryURL)
    try writer.append("# BorgVR mesh export\n")
    try writer.append("# Coordinates are expressed in meters.\n")
    try writer.append("mtllib \(materialURL.lastPathComponent)\n")
    try writer.append("o \(sanitizedFileStem(asset.name))\n")

    for vertex in asset.vertices {
      try writer.append(
        "v \(vertex.position.x) \(vertex.position.y) \(vertex.position.z) " +
          "\(vertex.color.x) \(vertex.color.y) \(vertex.color.z)\n"
      )
    }
    for vertex in asset.vertices {
      try writer.append("vt \(vertex.texcoord.x) \(vertex.texcoord.y)\n")
    }
    for vertex in asset.vertices {
      try writer.append("vn \(vertex.normal.x) \(vertex.normal.y) \(vertex.normal.z)\n")
    }
    try writer.append("usemtl BorgVRMaterial\n")
    for index in stride(from: 0, to: asset.indices.count, by: 3) {
      let a = asset.indices[index] + 1
      let b = asset.indices[index + 1] + 1
      let c = asset.indices[index + 2] + 1
      try writer.append("f \(a)/\(a)/\(a) \(b)/\(b)/\(b) \(c)/\(c)/\(c)\n")
    }
    try writer.finish()

    var material = "newmtl BorgVRMaterial\n"
    material += "Ka 0 0 0\n"
    material += "Kd \(asset.baseColor.x) \(asset.baseColor.y) \(asset.baseColor.z)\n"
    material += "Ks 0 0 0\n"
    material += "d 1\n"
    material += "illum 1\n"
    if let textureURL {
      material += "map_Kd \(textureURL.lastPathComponent)\n"
    }
    try Data(material.utf8).write(to: materialURL, options: .atomic)
    if let textureURL, let textureData = asset.textureData {
      try textureData.write(to: textureURL, options: .atomic)
    }

    if FileManager.default.fileExists(atPath: outputURL.path) {
      try FileManager.default.removeItem(at: outputURL)
    }
    try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
    logger?.info(
      "OBJ export completed: \(asset.vertices.count) vertices, " +
        "\(asset.indices.count / 3) triangles."
    )
    return outputURL
  }

  private static func textureURL(
    for asset: Mesh,
    directory: URL,
    baseName: String
  ) -> URL? {
    guard asset.textureData != nil else { return nil }
    let fileExtension: String
    switch asset.textureEncoding {
      case .png:
        fileExtension = "png"
      case .jpeg:
        fileExtension = "jpg"
      case .none:
        return nil
    }
    return directory
      .appendingPathComponent(baseName + "_texture")
      .appendingPathExtension(fileExtension)
  }

  private static func sanitizedFileStem(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let result = value.unicodeScalars
      .map { allowed.contains($0) ? String($0) : "_" }
      .joined()
    return result.isEmpty ? "mesh" : result
  }

  private static func decode(_ data: Data) throws -> Mesh {
    guard data.count <= BorgVRMeshFormat.maximumFileByteCount else {
      throw BorgVRMeshOBJExporterError.invalidFormat
    }
    var reader = DataReader(data)
    let magic = Data(BorgVRMeshFormat.magicBytes)
    guard try reader.readBytes(count: magic.count) == magic else {
      throw BorgVRMeshOBJExporterError.invalidFormat
    }
    let version: UInt16 = try reader.read()
    guard version == BorgVRMeshFormat.version else {
      throw BorgVRMeshOBJExporterError.unsupportedVersion(Int(version))
    }
    _ = try reader.read() as UInt16
    _ = try reader.readBytes(count: 16)

    let nameByteCount = Int(try reader.read() as UInt16)
    let descriptionByteCount = Int(try reader.read() as UInt16)
    guard nameByteCount <= BorgVRMeshFormat.maximumNameByteCount,
          descriptionByteCount <= BorgVRMeshFormat.maximumDescriptionByteCount,
          let name = String(data: try reader.readBytes(count: nameByteCount), encoding: .utf8),
          String(data: try reader.readBytes(count: descriptionByteCount), encoding: .utf8) != nil else {
      throw BorgVRMeshOBJExporterError.invalidFormat
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
          let textureEncoding = TextureEncoding(rawValue: rawTextureEncoding),
          baseColor.isFinite,
          boundsMinimum.isFinite,
          boundsMaximum.isFinite else {
      throw BorgVRMeshOBJExporterError.invalidGeometry
    }

    var vertices: [Vertex] = []
    vertices.reserveCapacity(vertexCount)
    for _ in 0..<vertexCount {
      let vertex = Vertex(
        position: try reader.readSIMD3(),
        normal: try reader.readSIMD3(),
        texcoord: SIMD2<Float>(try reader.read(), try reader.read()),
        color: try reader.readSIMD3()
      )
      guard vertex.isFinite else { throw BorgVRMeshOBJExporterError.invalidGeometry }
      vertices.append(vertex)
    }

    var indices: [UInt32] = []
    indices.reserveCapacity(indexCount)
    for _ in 0..<indexCount {
      let index: UInt32 = try reader.read()
      guard Int(index) < vertexCount else {
        throw BorgVRMeshOBJExporterError.invalidGeometry
      }
      indices.append(index)
    }

    let textureData = try reader.readBytes(count: textureByteCount)
    guard reader.isAtEnd,
          (textureEncoding == .none) == textureData.isEmpty else {
      throw BorgVRMeshOBJExporterError.invalidTexture
    }
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return Mesh(
      name: trimmedName.isEmpty ? "Object" : trimmedName,
      vertices: vertices,
      indices: indices,
      baseColor: baseColor,
      textureEncoding: textureEncoding,
      textureData: textureData.isEmpty ? nil : textureData
    )
  }

  private struct DataReader {
    private let data: Data
    private(set) var offset = 0

    init(_ data: Data) {
      self.data = data
    }

    var isAtEnd: Bool { offset == data.count }

    mutating func read<T>() throws -> T {
      let byteCount = MemoryLayout<T>.size
      guard byteCount > 0, offset <= data.count - byteCount else {
        throw BorgVRMeshOBJExporterError.invalidFormat
      }
      let value = data.withUnsafeBytes {
        $0.loadUnaligned(fromByteOffset: offset, as: T.self)
      }
      offset += byteCount
      return value
    }

    mutating func readSIMD3() throws -> SIMD3<Float> {
      SIMD3<Float>(try read(), try read(), try read())
    }

    mutating func readBytes(count: Int) throws -> Data {
      guard count >= 0, offset <= data.count - count else {
        throw BorgVRMeshOBJExporterError.invalidFormat
      }
      let result = data.subdata(in: offset..<(offset + count))
      offset += count
      return result
    }
  }

  private struct BufferedTextFileWriter {
    private static let flushThreshold = 1024 * 1024
    private let handle: FileHandle
    private var buffer = ""

    init(url: URL) throws {
      _ = FileManager.default.createFile(atPath: url.path, contents: nil)
      handle = try FileHandle(forWritingTo: url)
      buffer.reserveCapacity(Self.flushThreshold)
    }

    mutating func append(_ text: String) throws {
      buffer.append(text)
      if buffer.utf8.count >= Self.flushThreshold {
        try flush()
      }
    }

    mutating func finish() throws {
      try flush()
      try handle.close()
    }

    private mutating func flush() throws {
      guard !buffer.isEmpty else { return }
      try handle.write(contentsOf: Data(buffer.utf8))
      buffer.removeAll(keepingCapacity: true)
    }
  }
}

private extension SIMD2 where Scalar == Float {
  var isFinite: Bool { x.isFinite && y.isFinite }
}

private extension SIMD3 where Scalar == Float {
  var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}
#endif
