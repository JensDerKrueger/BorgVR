import Foundation
import simd

enum BorgVRDatasetViewStateFormat {
  static let fileExtension = "state"
  static let magicBytes = [UInt8]("BVRSTATE".utf8)
  static let version: UInt16 = 1
  static let maximumFileByteCount = 4096
}

struct DatasetViewCommonState {
  var renderMode: RenderMode
  var normalizedIsoValue: Float
  var clipMin: SIMD3<Float>
  var clipMax: SIMD3<Float>
  var lighting: BorgVRLightingState
}

struct DatasetScreenViewState {
  var orientation: simd_quatf
  var scale: Float
  var pan: SIMD2<Float>
}

struct DatasetSpatialViewState {
  /// Transform from dataset coordinates into a head-relative coordinate system.
  var headFromDataset: simd_float4x4
}

struct DatasetViewState {
  var datasetID: String
  var common: DatasetViewCommonState
  var screenView: DatasetScreenViewState?
  var spatialView: DatasetSpatialViewState?
}

enum DatasetViewStateDocument {
  private static let screenViewFlag: UInt16 = 1 << 0
  private static let spatialViewFlag: UInt16 = 1 << 1

  static func encode(_ state: DatasetViewState) throws -> Data {
    guard let datasetUUID = UUID(uuidString: state.datasetID),
          isValid(common: state.common) else {
      throw DatasetViewStateDocumentError.invalidState
    }

    var flags: UInt16 = 0
    if state.screenView != nil { flags |= screenViewFlag }
    if state.spatialView != nil { flags |= spatialViewFlag }

    var writer = MarkerDataWriter()
    writer.writeBytes(Data(BorgVRDatasetViewStateFormat.magicBytes))
    writer.write(BorgVRDatasetViewStateFormat.version)
    writer.write(flags)
    writer.writeUUID(datasetUUID)

    let common = sanitized(common: state.common)
    writer.write(common.renderMode.rawValue)
    writer.write(UInt8(0))
    writer.write(UInt16(0))
    writer.write(common.normalizedIsoValue)
    writer.writeSIMD3(common.clipMin)
    writer.writeSIMD3(common.clipMax)
    writer.writeSIMD3(common.lighting.direction)
    writer.writeSIMD3(common.lighting.ambientColor)
    writer.writeSIMD3(common.lighting.diffuseColor)
    writer.writeSIMD3(common.lighting.specularColor)

    if let screenView = state.screenView {
      guard isValid(screenView: screenView) else {
        throw DatasetViewStateDocumentError.invalidState
      }
      let orientation = simd_normalize(screenView.orientation)
      writer.writeSIMD4(orientation.vector)
      writer.write(screenView.scale)
      writer.write(screenView.pan.x)
      writer.write(screenView.pan.y)
    }

    if let spatialView = state.spatialView {
      guard isValid(spatialView: spatialView) else {
        throw DatasetViewStateDocumentError.invalidState
      }
      for column in 0..<4 {
        writer.writeSIMD4(spatialView.headFromDataset[column])
      }
    }

    guard writer.data.count <= BorgVRDatasetViewStateFormat.maximumFileByteCount else {
      throw DatasetViewStateDocumentError.fileTooLarge
    }
    return writer.data
  }

  static func decode(from data: Data) throws -> DatasetViewState {
    guard data.count <= BorgVRDatasetViewStateFormat.maximumFileByteCount else {
      throw DatasetViewStateDocumentError.fileTooLarge
    }

    do {
      var reader = MarkerDataReader(data)
      let magic = Data(BorgVRDatasetViewStateFormat.magicBytes)
      guard try reader.readBytes(count: magic.count) == magic else {
        throw DatasetViewStateDocumentError.invalidFormat
      }
      let version: UInt16 = try reader.read()
      guard version == BorgVRDatasetViewStateFormat.version else {
        throw DatasetViewStateDocumentError.unsupportedVersion(Int(version))
      }
      let flags: UInt16 = try reader.read()
      guard flags & ~(screenViewFlag | spatialViewFlag) == 0 else {
        throw DatasetViewStateDocumentError.invalidFormat
      }
      let datasetID = try reader.readUUID().uuidString
      let rawRenderMode: UInt8 = try reader.read()
      _ = try reader.read() as UInt8
      _ = try reader.read() as UInt16
      guard let renderMode = RenderMode(rawValue: rawRenderMode) else {
        throw DatasetViewStateDocumentError.invalidState
      }

      let common = DatasetViewCommonState(
        renderMode: renderMode,
        normalizedIsoValue: try reader.read(),
        clipMin: try reader.readSIMD3(),
        clipMax: try reader.readSIMD3(),
        lighting: BorgVRLightingState(
          direction: try reader.readSIMD3(),
          ambientColor: try reader.readSIMD3(),
          diffuseColor: try reader.readSIMD3(),
          specularColor: try reader.readSIMD3()
        )
      )
      guard isValid(common: common) else {
        throw DatasetViewStateDocumentError.invalidState
      }

      let screenView: DatasetScreenViewState?
      if flags & screenViewFlag != 0 {
        let view = DatasetScreenViewState(
          orientation: simd_quatf(vector: try reader.readSIMD4()),
          scale: try reader.read(),
          pan: SIMD2<Float>(try reader.read(), try reader.read())
        )
        guard isValid(screenView: view) else {
          throw DatasetViewStateDocumentError.invalidState
        }
        screenView = DatasetScreenViewState(
          orientation: simd_normalize(view.orientation),
          scale: view.scale,
          pan: view.pan
        )
      } else {
        screenView = nil
      }

      let spatialView: DatasetSpatialViewState?
      if flags & spatialViewFlag != 0 {
        let matrix = simd_float4x4(
          try reader.readSIMD4(),
          try reader.readSIMD4(),
          try reader.readSIMD4(),
          try reader.readSIMD4()
        )
        let view = DatasetSpatialViewState(headFromDataset: matrix)
        guard isValid(spatialView: view) else {
          throw DatasetViewStateDocumentError.invalidState
        }
        spatialView = view
      } else {
        spatialView = nil
      }

      guard reader.isAtEnd else {
        throw DatasetViewStateDocumentError.invalidFormat
      }
      return DatasetViewState(
        datasetID: datasetID,
        common: sanitized(common: common),
        screenView: screenView,
        spatialView: spatialView
      )
    } catch let error as DatasetViewStateDocumentError {
      throw error
    } catch {
      throw DatasetViewStateDocumentError.invalidFormat
    }
  }

  private static func sanitized(common: DatasetViewCommonState) -> DatasetViewCommonState {
    DatasetViewCommonState(
      renderMode: common.renderMode,
      normalizedIsoValue: min(max(common.normalizedIsoValue, 0), 1),
      clipMin: common.clipMin,
      clipMax: common.clipMax,
      lighting: common.lighting.sanitized
    )
  }

  private static func isValid(common: DatasetViewCommonState) -> Bool {
    common.normalizedIsoValue.isFinite &&
      (0...1).contains(common.normalizedIsoValue) &&
      isFinite(common.clipMin) && isFinite(common.clipMax) &&
      common.clipMin.x >= 0 && common.clipMin.y >= 0 && common.clipMin.z >= 0 &&
      common.clipMax.x <= 1 && common.clipMax.y <= 1 && common.clipMax.z <= 1 &&
      common.clipMin.x <= common.clipMax.x &&
      common.clipMin.y <= common.clipMax.y &&
      common.clipMin.z <= common.clipMax.z &&
      isFinite(common.lighting.direction) &&
      simd_length_squared(common.lighting.direction) > 0.000001 &&
      isFinite(common.lighting.ambientColor) &&
      isFinite(common.lighting.diffuseColor) &&
      isFinite(common.lighting.specularColor)
  }

  private static func isValid(screenView: DatasetScreenViewState) -> Bool {
    let orientation = screenView.orientation.vector
    return isFinite(orientation) && simd_length_squared(orientation) > 0.000001 &&
      screenView.scale.isFinite && screenView.scale > 0 &&
      screenView.pan.x.isFinite && screenView.pan.y.isFinite
  }

  private static func isValid(spatialView: DatasetSpatialViewState) -> Bool {
    let matrix = spatialView.headFromDataset
    let determinant = simd_determinant(matrix)
    return (0..<4).allSatisfy { isFinite(matrix[$0]) } &&
      determinant.isFinite && abs(determinant) > 0.00000001 &&
      abs(matrix.columns.0.w) < 0.0001 &&
      abs(matrix.columns.1.w) < 0.0001 &&
      abs(matrix.columns.2.w) < 0.0001 &&
      abs(matrix.columns.3.w - 1) < 0.0001
  }

  private static func isFinite(_ value: SIMD3<Float>) -> Bool {
    value.x.isFinite && value.y.isFinite && value.z.isFinite
  }

  private static func isFinite(_ value: SIMD4<Float>) -> Bool {
    value.x.isFinite && value.y.isFinite && value.z.isFinite && value.w.isFinite
  }
}

extension DatasetStateStorage {
  static let viewStateDirectoryName = "States"

  static func viewStateFileURL(datasetID: String, logger: LoggerBase? = nil) -> URL? {
    guard let directory = viewStateDirectoryURL(logger: logger) else { return nil }
    return directory
      .appendingPathComponent(sanitizedStateFilename(datasetID))
      .appendingPathExtension(BorgVRDatasetViewStateFormat.fileExtension)
  }

  static func viewStateDirectoryURL(logger: LoggerBase? = nil) -> URL? {
    guard let documentsURL = FileManager.default.urls(
      for: .documentDirectory,
      in: .userDomainMask
    ).first else { return nil }
    let directoryURL = documentsURL.appendingPathComponent(
      viewStateDirectoryName,
      isDirectory: true
    )
    do {
      try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true
      )
      return directoryURL
    } catch {
      logger?.warning("Dataset state directory unavailable: \(error.localizedDescription)")
      return nil
    }
  }

  static func loadViewState(datasetID: String, from url: URL) throws -> DatasetViewState {
    let state = try DatasetViewStateDocument.decode(
      from: Data(contentsOf: url, options: .mappedIfSafe)
    )
    guard state.datasetID.caseInsensitiveCompare(datasetID) == .orderedSame else {
      throw DatasetStateStorageError.datasetMismatch
    }
    return state
  }

  static func saveViewState(_ state: DatasetViewState, to url: URL) throws {
    var merged = state
    if FileManager.default.fileExists(atPath: url.path),
       let existing = try? DatasetViewStateDocument.decode(
        from: Data(contentsOf: url, options: .mappedIfSafe)
       ),
       existing.datasetID.caseInsensitiveCompare(state.datasetID) == .orderedSame {
      if merged.screenView == nil { merged.screenView = existing.screenView }
      if merged.spatialView == nil { merged.spatialView = existing.spatialView }
    }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try DatasetViewStateDocument.encode(merged).write(to: url, options: .atomic)
  }

  private static func sanitizedStateFilename(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    let scalars = value.unicodeScalars.map { scalar in
      allowed.contains(scalar) ? Character(scalar) : "_"
    }
    let result = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
    return result.isEmpty ? "dataset" : result
  }
}

#if os(iOS) || os(macOS)
extension RenderingParameters {
  func makeDatasetViewState(datasetID: String) -> DatasetViewState {
    DatasetViewState(
      datasetID: datasetID,
      common: DatasetViewCommonState(
        renderMode: renderMode,
        normalizedIsoValue: normIsoValue,
        clipMin: clipMin,
        clipMax: clipMax,
        lighting: BorgVRLightingState(
          direction: lightDirection,
          ambientColor: ambientLightColor,
          diffuseColor: diffuseLightColor,
          specularColor: specularLightColor
        )
      ),
      screenView: DatasetScreenViewState(
        orientation: orientation,
        scale: scale,
        pan: pan
      ),
      spatialView: nil
    )
  }

  func applyDatasetViewState(_ state: DatasetViewState) {
    let common = state.common
    renderMode = common.renderMode
    normIsoValue = common.normalizedIsoValue
    clipMin = common.clipMin
    clipMax = common.clipMax
    clippingTranslation = Self.translationFromClippingBounds(
      clipMin: common.clipMin,
      clipMax: common.clipMax
    )
    let lighting = common.lighting.sanitized
    lightDirection = lighting.direction
    ambientLightColor = lighting.ambientColor
    diffuseLightColor = lighting.diffuseColor
    specularLightColor = lighting.specularColor

    if let screenView = state.screenView {
      orientation = screenView.orientation
      scale = screenView.scale
      pan = screenView.pan
    }
  }

  private static func translationFromClippingBounds(
    clipMin: SIMD3<Float>,
    clipMax: SIMD3<Float>
  ) -> SIMD3<Float> {
    var translation = SIMD3<Float>(repeating: 0)
    for axis in 0..<3 {
      if clipMin[axis] > 0 {
        translation[axis] = clipMin[axis]
      } else if clipMax[axis] < 1 {
        translation[axis] = clipMax[axis] - 1
      }
    }
    return translation
  }
}
#endif

enum DatasetViewStateDocumentError: LocalizedError {
  case invalidFormat
  case unsupportedVersion(Int)
  case invalidState
  case fileTooLarge
  case spatialPoseUnavailable

  var errorDescription: String? {
    switch self {
      case .invalidFormat:
        String(localized: "The dataset state file is invalid.")
      case .unsupportedVersion(let version):
        String(format: String(localized: "Unsupported dataset state version %d."), version)
      case .invalidState:
        String(localized: "The dataset state contains invalid values.")
      case .fileTooLarge:
        String(localized: "The dataset state file is too large.")
      case .spatialPoseUnavailable:
        String(localized: "The spatial view is not available yet.")
    }
  }
}

extension simd_float4x4 {
  var isFiniteAffine: Bool {
    (0..<4).allSatisfy {
      self[$0].x.isFinite && self[$0].y.isFinite &&
        self[$0].z.isFinite && self[$0].w.isFinite
    } && abs(columns.0.w) < 0.0001 && abs(columns.1.w) < 0.0001 &&
      abs(columns.2.w) < 0.0001 && abs(columns.3.w - 1) < 0.0001 &&
      abs(simd_determinant(self)) > 0.00000001
  }
}
