import Foundation

struct LightingPanelPreset: Codable {
  var direction: SIMD3<Float>
  var ambient: SIMD3<Float>
  var diffuse: SIMD3<Float>
  var specular: SIMD3<Float>

  init(state: BorgVRLightingState) {
    self.init(direction: state.direction, ambient: state.ambientColor,
      diffuse: state.diffuseColor, specular: state.specularColor)
  }

  init(direction: SIMD3<Float>, ambient: SIMD3<Float>, diffuse: SIMD3<Float>, specular: SIMD3<Float>) {
    self.direction = direction
    self.ambient = ambient
    self.diffuse = diffuse
    self.specular = specular
  }

  var state: BorgVRLightingState {
    BorgVRLightingState(direction: direction, ambientColor: ambient,
      diffuseColor: diffuse, specularColor: specular).sanitized
  }
}

struct IsoPanelPreset: Codable {
  var value: Float
}

struct BrushPanelPreset: Codable {
  var mode: BorgVRVolumeBrushMode
  var radius: Double
  var projectsOntoVolume: Bool
  var channels: BorgVRVolumeEditChannels

  @MainActor init(model: VolumeBrushModel) {
    self.init(mode: model.mode, radius: model.radius,
      projectsOntoVolume: model.projectsOntoVolume, channels: model.channels)
  }

  init(mode: BorgVRVolumeBrushMode, radius: Double, projectsOntoVolume: Bool,
       channels: BorgVRVolumeEditChannels) {
    self.mode = mode
    self.radius = radius
    self.projectsOntoVolume = projectsOntoVolume
    self.channels = channels
  }

  @MainActor func apply(to model: VolumeBrushModel) throws {
    guard radius.isFinite, BorgVRVolumeBrushLimits.radiusFraction.contains(radius) else {
      throw PanelPresetError.invalid
    }
    try model.setVolumeBrushChannels(channels)
    model.mode = mode
    model.radius = radius
    model.projectsOntoVolume = projectsOntoVolume
  }
}

enum PanelPresetError: LocalizedError {
  case invalid
  var errorDescription: String? { String(localized: "Invalid panel settings.") }
}

enum PanelParameterStorage {
  private struct Envelope<Value: Codable>: Codable {
    let format: String
    let version: Int
    let panel: String
    let value: Value
  }

  static func encode<Value: Codable>(_ value: Value, kind: String) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(Envelope(format: "borgvr.panel", version: 1, panel: kind, value: value))
  }

  static func decode<Value: Codable>(_ type: Value.Type, kind: String, data: Data) throws -> Value {
    guard data.count <= 1_000_000 else { throw PanelPresetError.invalid }
    let envelope = try JSONDecoder().decode(Envelope<Value>.self, from: data)
    guard envelope.format == "borgvr.panel", envelope.version == 1, envelope.panel == kind else {
      throw PanelPresetError.invalid
    }
    return envelope.value
  }

  static func load<Value: Codable>(_ type: Value.Type, kind: String, from url: URL) throws -> Value {
    guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_000_000 else {
      throw PanelPresetError.invalid
    }
    return try decode(type, kind: kind, data: Data(contentsOf: url, options: .mappedIfSafe))
  }

  static func fileURL(kind: String, beside viewStateURL: URL) -> URL {
    viewStateURL.deletingPathExtension().appendingPathExtension(kind).appendingPathExtension("json")
  }

  static func datasetFileURLs(beside viewStateURL: URL) -> [URL] {
    ["lighting", "isovalue", "brush"].map { fileURL(kind: $0, beside: viewStateURL) }
  }

  @MainActor static func saveDataset(common: DatasetViewCommonState, brush: VolumeBrushModel,
                                     beside viewStateURL: URL) throws {
    let files: [(String, Data)] = [
      ("lighting", try encode(LightingPanelPreset(state: common.lighting), kind: "lighting")),
      ("isovalue", try encode(IsoPanelPreset(value: common.normalizedIsoValue), kind: "isovalue")),
      ("brush", try encode(BrushPanelPreset(model: brush), kind: "brush"))
    ]
    try FileManager.default.createDirectory(at: viewStateURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    for (kind, data) in files {
      try data.write(to: fileURL(kind: kind, beside: viewStateURL), options: .atomic)
    }
  }

  struct DatasetParameters {
    let lighting: LightingPanelPreset?
    let iso: IsoPanelPreset?
    let brush: BrushPanelPreset?
    var isEmpty: Bool { lighting == nil && iso == nil && brush == nil }
  }

  static func loadDataset(beside viewStateURL: URL) throws -> DatasetParameters {
    func optional<Value: Codable>(_ type: Value.Type, kind: String) throws -> Value? {
      let url = fileURL(kind: kind, beside: viewStateURL)
      guard FileManager.default.fileExists(atPath: url.path) else { return nil }
      return try load(type, kind: kind, from: url)
    }
    let iso = try optional(IsoPanelPreset.self, kind: "isovalue")
    if let iso, !iso.value.isFinite || !(0...1).contains(iso.value) { throw PanelPresetError.invalid }
    return try DatasetParameters(lighting: optional(LightingPanelPreset.self, kind: "lighting"),
      iso: iso, brush: optional(BrushPanelPreset.self, kind: "brush"))
  }
}

#if os(iOS) || os(macOS)
extension RenderingParameters {
  @MainActor @discardableResult
  func loadPanelParameters(beside url: URL, brush: VolumeBrushModel) throws -> Bool {
    let parameters = try PanelParameterStorage.loadDataset(beside: url)
    try parameters.brush?.apply(to: brush)
    if let lighting = parameters.lighting?.state {
      lightDirection = lighting.direction
      ambientLightColor = lighting.ambientColor
      diffuseLightColor = lighting.diffuseColor
      specularLightColor = lighting.specularColor
    }
    if let iso = parameters.iso { normIsoValue = iso.value }
    return !parameters.isEmpty
  }
}
#endif
