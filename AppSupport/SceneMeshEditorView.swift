import SwiftUI
import UniformTypeIdentifiers
import simd

struct SceneMeshEditorView: View {
  @Environment(\.dismiss) private var dismiss

  @Binding var assets: [UUID: SceneMeshAsset]
  @Binding var instances: [SceneMeshInstance]
  @Binding var selectedInstanceID: UUID?
  let datasetExtentMeters: SIMD3<Float>?
  let logger: LoggerBase?
  let synchronize: () -> Void
  var handleImportedAsset: ((SceneMeshAsset) -> Bool)? = nil

  @State private var showImporter = false
  @State private var pendingAsset: SceneMeshAsset?
  @State private var pendingInstance: SceneMeshInstance?
  @State private var scaleWarning: SceneMeshScaleAssessment?
  @State private var importError: Error?

  var body: some View {
    NavigationStack {
      Form {
        Section("Meshes") {
          if instances.isEmpty {
            ContentUnavailableView(
              "No Meshes",
              systemImage: "cube.transparent",
              description: Text("Import a BorgVR mesh to place opaque geometry in the volume scene.")
            )
          } else {
            ForEach(instances) { instance in
              Button {
                selectedInstanceID = instance.id
              } label: {
                HStack {
                  Image(systemName: instance.isVisible ? "cube.fill" : "cube")
                  VStack(alignment: .leading, spacing: 2) {
                    Text(instance.name)
                      .foregroundStyle(.primary)
                    Text(assetStatus(for: instance))
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                  Spacer()
                  if selectedInstanceID == instance.id {
                    Image(systemName: "checkmark")
                  }
                }
              }
              .buttonStyle(.plain)
            }
          }

          Button {
            showImporter = true
          } label: {
            Label("Import Mesh…", systemImage: "square.and.arrow.down")
          }
        }

        if let selectedIndex {
          Section("Selected Mesh Instance") {
            TextField("Name", text: nameBinding(index: selectedIndex))
            Toggle("Visible", isOn: visibilityBinding(index: selectedIndex))

            vectorEditor(
              title: "Position (m)",
              vector: vectorBinding(index: selectedIndex, keyPath: \.translationMeters)
            )
            vectorEditor(
              title: "Scale",
              vector: vectorBinding(index: selectedIndex, keyPath: \.scale),
              minimum: 0.000_001
            )

            LabeledContent("Rotation") {
              TextField(
                "Degrees",
                value: rotationAngleBinding(index: selectedIndex),
                format: .number.precision(.fractionLength(1))
              )
              .frame(minWidth: 80)
            }
            vectorEditor(
              title: "Rotation Axis",
              vector: rotationAxisBinding(index: selectedIndex)
            )

            HStack {
              Button {
                duplicateSelectedInstance()
              } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
              }
              Spacer()
              Button(role: .destructive) {
                removeSelectedInstance()
              } label: {
                Label("Delete", systemImage: "trash")
              }
            }
          }
        }
      }
      .navigationTitle("Meshes")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .frame(minWidth: 500, minHeight: 560)
    .fileImporter(
      isPresented: $showImporter,
      allowedContentTypes: [.borgVRMesh],
      allowsMultipleSelection: false,
      onCompletion: importMesh
    )
    .confirmationDialog(
      "Unusual Mesh Size",
      isPresented: Binding(
        get: { scaleWarning != nil },
        set: { if !$0 { discardPendingImport() } }
      ),
      titleVisibility: .visible
    ) {
      Button("Add Without Scaling") { commitPendingImport() }
      Button("Cancel", role: .cancel) { discardPendingImport() }
    } message: {
      Text(scaleWarningMessage)
    }
    .alert(
      "Mesh Import Failed",
      isPresented: Binding(
        get: { importError != nil },
        set: { if !$0 { importError = nil } }
      ),
      presenting: importError
    ) { _ in
      Button("OK", role: .cancel) { importError = nil }
    } message: { error in
      Text(error.localizedDescription)
    }
    .onAppear {
      refreshAssets()
    }
    .onReceive(NotificationCenter.default.publisher(for: SceneMeshAssetCatalog.didChangeNotification)) { _ in
      refreshAssets()
    }
  }

  private var selectedIndex: Int? {
    guard let selectedInstanceID else { return nil }
    return instances.firstIndex { $0.id == selectedInstanceID }
  }

  private func refreshAssets() {
    for asset in SceneMeshAssetCatalog.allAssets(logger: logger) {
      assets[asset.id] = asset
    }
  }

  private func assetStatus(for instance: SceneMeshInstance) -> String {
    if assets[instance.asset.assetID] != nil {
      return instance.asset.name
    }
    return String(localized: "Mesh data unavailable")
  }

  @ViewBuilder
  private func vectorEditor(
    title: LocalizedStringKey,
    vector: Binding<SIMD3<Float>>,
    minimum: Float? = nil
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack {
        ForEach(Array(["X", "Y", "Z"].enumerated()), id: \.offset) { component, label in
          LabeledContent(label) {
            TextField(
              label,
              value: componentBinding(vector, component: component, minimum: minimum),
              format: .number.precision(.fractionLength(4))
            )
            .frame(minWidth: 72)
          }
        }
      }
    }
  }

  private func nameBinding(index: Int) -> Binding<String> {
    Binding(
      get: { instances.indices.contains(index) ? instances[index].name : "" },
      set: { value in
        guard instances.indices.contains(index) else { return }
        instances[index].name = String(value.prefix(BorgVRMeshFormat.maximumNameCharacterCount))
        synchronize()
      }
    )
  }

  private func visibilityBinding(index: Int) -> Binding<Bool> {
    Binding(
      get: { instances.indices.contains(index) && instances[index].isVisible },
      set: { value in
        guard instances.indices.contains(index) else { return }
        instances[index].isVisible = value
        synchronize()
      }
    )
  }

  private func vectorBinding(
    index: Int,
    keyPath: WritableKeyPath<SceneMeshInstance, SIMD3<Float>>
  ) -> Binding<SIMD3<Float>> {
    Binding(
      get: { instances.indices.contains(index) ? instances[index][keyPath: keyPath] : .zero },
      set: { value in
        guard instances.indices.contains(index) else { return }
        instances[index][keyPath: keyPath] = value
        synchronize()
      }
    )
  }

  private func componentBinding(
    _ vector: Binding<SIMD3<Float>>,
    component: Int,
    minimum: Float?
  ) -> Binding<Float> {
    Binding(
      get: { vector.wrappedValue[component] },
      set: { value in
        guard value.isFinite else { return }
        var result = vector.wrappedValue
        result[component] = minimum.map { max($0, value) } ?? value
        vector.wrappedValue = result
      }
    )
  }

  private func rotationAngleBinding(index: Int) -> Binding<Float> {
    Binding(
      get: {
        guard instances.indices.contains(index) else { return 0 }
        return instances[index].rotation.angle * 180 / .pi
      },
      set: { degrees in
        guard instances.indices.contains(index), degrees.isFinite else { return }
        let axis = safeRotationAxis(instances[index].rotation.axis)
        instances[index].rotation = simd_quatf(angle: degrees * .pi / 180, axis: axis)
        synchronize()
      }
    )
  }

  private func rotationAxisBinding(index: Int) -> Binding<SIMD3<Float>> {
    Binding(
      get: {
        guard instances.indices.contains(index) else { return SIMD3<Float>(0, 1, 0) }
        return safeRotationAxis(instances[index].rotation.axis)
      },
      set: { axis in
        guard instances.indices.contains(index) else { return }
        let angle = instances[index].rotation.angle
        instances[index].rotation = simd_quatf(angle: angle, axis: safeRotationAxis(axis))
        synchronize()
      }
    )
  }

  private func safeRotationAxis(_ axis: SIMD3<Float>) -> SIMD3<Float> {
    let lengthSquared = simd_length_squared(axis)
    guard lengthSquared.isFinite, lengthSquared > 0.000_001 else {
      return SIMD3<Float>(0, 1, 0)
    }
    return axis / sqrt(lengthSquared)
  }

  private func importMesh(_ result: Result<[URL], Error>) {
    do {
      guard let url = try result.get().first else { return }
      let hasSecurityScope = url.startAccessingSecurityScopedResource()
      defer { if hasSecurityScope { url.stopAccessingSecurityScopedResource() } }
      let asset = try SceneMeshDocument.decode(from: Data(contentsOf: url, options: .mappedIfSafe))
      let instance = SceneMeshInstance(
        name: nextInstanceName(for: asset.name),
        asset: asset.reference
      )
      pendingAsset = asset
      pendingInstance = instance
      let assessment = SceneMeshScaleValidator.assess(
        instance: instance,
        datasetExtentMeters: datasetExtentMeters
      )
      switch assessment {
        case .tooSmall, .tooLarge:
          scaleWarning = assessment
        case .plausible, .unavailable:
          commitPendingImport()
      }
    } catch {
      importError = error
    }
  }

  private func commitPendingImport() {
    guard let asset = pendingAsset, let instance = pendingInstance else {
      discardPendingImport()
      return
    }
    do {
      try SceneMeshAssetCatalog.store(asset, logger: logger)
      assets[asset.id] = asset
      if handleImportedAsset?(asset) == true {
        discardPendingImport()
        return
      }
      instances.append(instance)
      selectedInstanceID = instance.id
      discardPendingImport()
      synchronize()
    } catch {
      discardPendingImport()
      importError = error
    }
  }

  private func discardPendingImport() {
    pendingAsset = nil
    pendingInstance = nil
    scaleWarning = nil
  }

  private var scaleWarningMessage: String {
    switch scaleWarning {
      case .tooSmall(let ratio):
        return String(
          format: String(localized: "The mesh is only %.4g times the dataset size. Add it at its physical size anyway?"),
          ratio
        )
      case .tooLarge(let ratio):
        return String(
          format: String(localized: "The mesh is %.4g times the dataset size. Add it at its physical size anyway?"),
          ratio
        )
      case .plausible, .unavailable, nil:
        return ""
    }
  }

  private func nextInstanceName(for assetName: String) -> String {
    let usedNames = Set(instances.map(\.name))
    if !usedNames.contains(assetName) { return assetName }
    var index = 2
    while usedNames.contains("\(assetName) \(index)") { index += 1 }
    return "\(assetName) \(index)"
  }

  private func duplicateSelectedInstance() {
    guard let selectedIndex else { return }
    var copy = instances[selectedIndex]
    copy.id = UUID()
    copy.name = nextInstanceName(for: copy.asset.name)
    instances.append(copy)
    selectedInstanceID = copy.id
    synchronize()
  }

  private func removeSelectedInstance() {
    guard let selectedInstanceID else { return }
    instances.removeAll { $0.id == selectedInstanceID }
    self.selectedInstanceID = nil
    synchronize()
  }
}
