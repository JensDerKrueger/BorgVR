import Foundation

// Small model doubles keep this file-format test independent of the renderer.
enum BorgVRVolumeBrushMode: String, Codable { case erase, restore }
enum BorgVRVolumeEditChannels: Codable, Equatable { case all, selected([Int]) }
enum BorgVRVolumeBrushLimits { static let radiusFraction = 0.002...0.15 }
struct BorgVRLightingState {
  var direction: SIMD3<Float>
  var ambientColor: SIMD3<Float>
  var diffuseColor: SIMD3<Float>
  var specularColor: SIMD3<Float>
  var sanitized: Self { self }
}
struct DatasetViewCommonState {
  var lighting: BorgVRLightingState
  var normalizedIsoValue: Float
}
@MainActor final class VolumeBrushModel {
  var mode = BorgVRVolumeBrushMode.erase
  var radius = 0.03
  var projectsOntoVolume = true
  var channels = BorgVRVolumeEditChannels.all
  func setVolumeBrushChannels(_ channels: BorgVRVolumeEditChannels) throws { self.channels = channels }
}
final class RenderingParameters {
  var lightDirection = SIMD3<Float>(0, 0, 1)
  var ambientLightColor = SIMD3<Float>(repeating: 0.15)
  var diffuseLightColor = SIMD3<Float>(repeating: 0.8)
  var specularLightColor = SIMD3<Float>(repeating: 1)
  var normIsoValue: Float = 0.1
}

@main @MainActor
struct PanelParameterStorageTests {
  static func rejected(_ action: () throws -> Void) {
    do { try action(); preconditionFailure("Expected an invalid preset to be rejected") }
    catch {}
  }

  static func main() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let base = directory.appendingPathComponent("dataset.state")
    let brush = VolumeBrushModel()
    brush.mode = .restore
    brush.radius = 0.07
    brush.channels = .selected([1])
    let common = DatasetViewCommonState(lighting: .init(direction: SIMD3(1, 0, 0),
      ambientColor: SIMD3(repeating: 0.2), diffuseColor: SIMD3(repeating: 0.6),
      specularColor: SIMD3(repeating: 0.9)), normalizedIsoValue: 0.4)
    try PanelParameterStorage.saveDataset(common: common, brush: brush, beside: base)
    let urls = PanelParameterStorage.datasetFileURLs(beside: base)
    precondition(urls.map(\.lastPathComponent) == ["dataset.lighting.json", "dataset.isovalue.json", "dataset.brush.json"])
    precondition(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    let lightingData = try Data(contentsOf: urls[0])
    let individualData = try PanelParameterStorage.encode(LightingPanelPreset(state: common.lighting), kind: "lighting")
    precondition(lightingData == individualData,
      "Save All must use exactly the individual panel format")
    let parameters = RenderingParameters()
    let targetBrush = VolumeBrushModel()
    let restored = try parameters.loadPanelParameters(beside: base, brush: targetBrush)
    precondition(restored && parameters.normIsoValue == 0.4 && parameters.lightDirection == SIMD3(1, 0, 0))
    precondition(targetBrush.radius == 0.07 && targetBrush.mode == .restore && targetBrush.channels == .selected([1]))

    // Files saved individually must override the matching Save All snapshot.
    try PanelParameterStorage.encode(IsoPanelPreset(value: 0.8), kind: "isovalue").write(to: urls[1])
    _ = try parameters.loadPanelParameters(beside: base, brush: targetBrush)
    precondition(parameters.normIsoValue == 0.8)
    try FileManager.default.removeItem(at: urls[0])
    let partial = try PanelParameterStorage.loadDataset(beside: base)
    precondition(partial.lighting == nil)
    rejected { _ = try PanelParameterStorage.load(IsoPanelPreset.self, kind: "lighting", from: urls[1]) }
    let wrongVersion = Data(#"{"format":"borgvr.panel","version":2,"panel":"isovalue","value":{"value":0.5}}"#.utf8)
    rejected { _ = try PanelParameterStorage.decode(IsoPanelPreset.self, kind: "isovalue", data: wrongVersion) }
    rejected { _ = try PanelParameterStorage.decode(IsoPanelPreset.self, kind: "isovalue", data: Data(repeating: 0, count: 1_000_001)) }
    try PanelParameterStorage.encode(IsoPanelPreset(value: 2), kind: "isovalue").write(to: urls[1])
    rejected { _ = try PanelParameterStorage.loadDataset(beside: base) }
    let invalidBrush = BrushPanelPreset(mode: .erase, radius: -1, projectsOntoVolume: false, channels: .all)
    rejected { try invalidBrush.apply(to: targetBrush) }
    precondition(targetBrush.radius == 0.07 && targetBrush.mode == .restore)
    print("Panel JSON roundtrip, shared Save All format, file naming and invalid-input tests passed")
  }
}
