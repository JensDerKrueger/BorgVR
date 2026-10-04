import SwiftUI

struct SceneObjectCatalogView: View {
  @Binding var assets: [UUID: SceneMeshAsset]
  @Binding var selectedPrototype: SceneObjectPrototype
  let datasetExtentMeters: SIMD3<Float>?
  let logger: LoggerBase?
  var additionalDirectoryURLs: [URL] = []

  @State private var pendingPrototype: SceneObjectPrototype?
  @State private var scaleWarning: SceneMeshScaleAssessment?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Picker("Active Object", selection: selectionBinding) {
        Label("Sphere", systemImage: "circle.fill")
          .tag(SceneObjectPrototype.sphere)
        ForEach(sortedAssets) { asset in
          Label(asset.name, systemImage: "cube.fill")
            .tag(SceneObjectPrototype.mesh(asset.id))
        }
      }

      Text(selectedObjectDescription)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .confirmationDialog(
      "Unusual Object Size",
      isPresented: Binding(
        get: { scaleWarning != nil },
        set: { if !$0 { discardPendingSelection() } }
      ),
      titleVisibility: .visible
    ) {
      Button("Use Physical Size") { commitPendingSelection() }
      Button("Cancel", role: .cancel) { discardPendingSelection() }
    } message: {
      Text(scaleWarningMessage)
    }
    .onAppear(perform: refreshAssets)
    .onReceive(NotificationCenter.default.publisher(for: SceneMeshAssetCatalog.didChangeNotification)) { _ in
      refreshAssets()
    }
  }

  private var sortedAssets: [SceneMeshAsset] {
    assets.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  private var selectionBinding: Binding<SceneObjectPrototype> {
    Binding(
      get: { selectedPrototype },
      set: validateSelection
    )
  }

  private var selectedObjectDescription: String {
    switch selectedPrototype {
      case .sphere:
        return String(localized: "A solid sphere using the current object color and radius.")
      case .mesh(let id):
        guard let asset = assets[id] else {
          return String(localized: "The selected object is not available locally.")
        }
        let description = asset.assetDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? asset.name : description
    }
  }

  private func refreshAssets() {
    for asset in SceneMeshAssetCatalog.allAssets(
      additionalDirectoryURLs: additionalDirectoryURLs,
      logger: logger
    ) {
      assets[asset.id] = asset
    }
    if case .mesh(let id) = selectedPrototype, assets[id] == nil {
      selectedPrototype = .sphere
    }
  }

  private func validateSelection(_ prototype: SceneObjectPrototype) {
    guard case .mesh(let assetID) = prototype,
          let asset = assets[assetID] else {
      selectedPrototype = prototype
      return
    }
    let assessment = SceneMeshScaleValidator.assess(
      instance: SceneMeshInstance(name: asset.name, asset: asset.reference),
      datasetExtentMeters: datasetExtentMeters
    )
    switch assessment {
      case .tooSmall, .tooLarge:
        pendingPrototype = prototype
        scaleWarning = assessment
      case .plausible, .unavailable:
        selectedPrototype = prototype
    }
  }

  private func commitPendingSelection() {
    if let pendingPrototype {
      selectedPrototype = pendingPrototype
    }
    discardPendingSelection()
  }

  private func discardPendingSelection() {
    pendingPrototype = nil
    scaleWarning = nil
  }

  private var scaleWarningMessage: String {
    switch scaleWarning {
      case .tooSmall(let ratio):
        return String(
          format: String(localized: "The object is only %.4g times the dataset size. Use it at its physical size anyway?"),
          ratio
        )
      case .tooLarge(let ratio):
        return String(
          format: String(localized: "The object is %.4g times the dataset size. Use it at its physical size anyway?"),
          ratio
        )
      case .plausible, .unavailable, nil:
        return ""
    }
  }
}
