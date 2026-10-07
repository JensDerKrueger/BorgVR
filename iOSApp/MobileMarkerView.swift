import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MobileMarkerView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var sharePlay: SharePlayCoordinator
  @State private var confirmDeleteAll = false
  @State private var showLoadFilePicker = false
  @State private var showSaveFilePicker = false
  @State private var pendingLoadedMarkers: [VolumeMarker] = []
  @State private var pendingLoadedMeshInstances: [SceneMeshInstance] = []
  @State private var showLoadMergeChoice = false
  @State private var showDatasetMismatchWarning = false
  @State private var markerCatalog: [VolumeMarkerCatalogEntry] = []
  @State private var markerFileError: Error?
  @State private var showMarkerFileError = false

  var body: some View {
    NavigationStack {
      Form {
        Section("Active Object") {
          SceneObjectCatalogView(
            assets: $appModel.sceneMeshAssets,
            selectedPrototype: $appModel.selectedSceneObjectPrototype,
            datasetExtentMeters: appModel.activeDatasetMetadata?.physicalExtentMeters,
            logger: appModel.logger,
            additionalDirectoryURLs: FileManager.default.urls(
              for: .documentDirectory,
              in: .userDomainMask
            )
          )
          Toggle("Project onto Volume", isOn: $appModel.projectObjectsOntoVolume)
        }

        Section("Objects") {
          if appModel.volumeMarkers.isEmpty && appModel.sceneMeshInstances.isEmpty {
            ContentUnavailableView(
              "No Objects",
              systemImage: "cube.transparent",
              description: Text("Choose Draw or Place and interact with the rendering view.")
            )
          } else {
            ForEach(appModel.volumeMarkers) { marker in
              Button {
                var selection = appModel.selectedVolumeMarkerIDs
                if selection.contains(marker.id) {
                  selection.remove(marker.id)
                } else {
                  selection.insert(marker.id)
                }
                appModel.setVolumeMarkerSelection(selection, primary: marker.id)
                appModel.selectedSceneMeshInstanceID = nil
                appModel.interactionMode = marker.kind == .stroke ? .drawing : .objectPlacement
              } label: {
                HStack {
                  Circle()
                    .fill(color(from: marker.color))
                    .frame(width: 16, height: 16)
                  VStack(alignment: .leading, spacing: 1) {
                    Text(marker.name)
                      .foregroundStyle(.primary)
                    Text(
                      marker.kind == .sphere
                        ? String(localized: "Sphere")
                        : String(localized: "Stroke")
                    )
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                  Spacer()
                  if appModel.selectedVolumeMarkerIDs.contains(marker.id) {
                    Image(systemName: "checkmark")
                  }
                }
              }
            }
            ForEach(appModel.sceneMeshInstances) { instance in
              Button {
                appModel.clearVolumeMarkerSelection()
                appModel.selectedSceneMeshInstanceID = instance.id
                appModel.interactionMode = .objectPlacement
              } label: {
                HStack {
                  Image(systemName: "cube.fill")
                    .foregroundStyle(.tint)
                  VStack(alignment: .leading, spacing: 1) {
                    Text(instance.name)
                      .foregroundStyle(.primary)
                    Text(instance.asset.assetDescription.isEmpty
                      ? instance.asset.name
                      : instance.asset.assetDescription)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .lineLimit(2)
                  }
                  Spacer()
                  if appModel.selectedSceneMeshInstanceID == instance.id {
                    Image(systemName: "checkmark")
                  }
                }
              }
            }
          }
        }

        if !selectedMarkerIndices.isEmpty {
          Section(selectedMarkersTitle) {
            if selectedMarkerIndices.count == 1 {
              TextField("Name", text: selectedNameBinding)
            }
            ColorPicker("Color", selection: selectedColorBinding, supportsOpacity: false)
            LabeledContent("Radius") {
              Text(selectedRadiusBinding.wrappedValue, format: .number.precision(.fractionLength(3)))
                .monospacedDigit()
            }
            Slider(value: selectedRadiusBinding, in: selectedRadiusRange)

            if selectionContainsSphere {
              Toggle("Show Direction", isOn: selectedDirectionBinding)
            }

            Button(deleteSelectedMarkersTitle, role: .destructive) {
              deleteSelectedMarker()
            }
          }
        }

        if let selectedObject = selectedSceneObject {
          Section("Selected Object") {
            LabeledContent("Name", value: selectedObject.name)
            Text(selectedObject.asset.assetDescription.isEmpty
              ? selectedObject.asset.name
              : selectedObject.asset.assetDescription)
              .foregroundStyle(.secondary)

            Button("Delete Selected Object", role: .destructive) {
              deleteSelectedMarker()
            }
          }
        }

        Section("Object Files") {
          Menu {
            if markerCatalog.isEmpty {
              Text("No Object Files Available")
            } else {
              ForEach(markerCatalog) { entry in
                Button {
                  loadMarkers(at: entry.url)
                } label: {
                  Label(
                    entry.displayName,
                    systemImage: entry.matches(datasetID: currentDatasetID)
                      ? "checkmark.circle.fill" : "doc"
                  )
                }
              }
            }
          } label: {
            Label("Object Files", systemImage: "shippingbox")
          }

          Button {
            showLoadFilePicker = true
          } label: {
            Label("Load Objects...", systemImage: "folder")
          }

          Button {
            showSaveFilePicker = true
          } label: {
            Label("Save Objects...", systemImage: "square.and.arrow.down")
          }
          .disabled(appModel.volumeMarkers.isEmpty && appModel.sceneMeshInstances.isEmpty)
        }

        Section {
          Button("Delete All Objects", role: .destructive) {
            confirmDeleteAll = true
          }
          .disabled(appModel.volumeMarkers.isEmpty && appModel.sceneMeshInstances.isEmpty)
        }
      }
      .navigationTitle("Objects")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button {
            dismiss()
          } label: {
            Label("Done", systemImage: "checkmark")
          }
        }
      }
      .confirmationDialog(
        "Delete All Objects?",
        isPresented: $confirmDeleteAll,
        titleVisibility: .visible
      ) {
        Button("Delete All Objects", role: .destructive) {
          let hadObjects = !appModel.volumeMarkers.isEmpty || !appModel.sceneMeshInstances.isEmpty
          _ = appModel.removeAllVolumeMarkers()
          appModel.sceneMeshInstances.removeAll()
          appModel.selectedSceneMeshInstanceID = nil
          if hadObjects {
            synchronizeMarkers()
          }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("This removes every annotation object from the current session.")
      }
      .confirmationDialog(
        "Objects for a Different Dataset",
        isPresented: $showDatasetMismatchWarning,
        titleVisibility: .visible
      ) {
        Button("Load Anyway") { continueLoadingMarkers() }
        Button("Cancel", role: .cancel) { clearPendingLoad() }
      } message: {
        Text("This object file was created for a different dataset. Its positions may not match the current volume. Do you still want to load it?")
      }
      .confirmationDialog(
        "Load Objects",
        isPresented: $showLoadMergeChoice,
        titleVisibility: .visible
      ) {
        Button("Replace Existing Objects", role: .destructive) {
          applyLoadedMarkers(replacingExisting: true)
        }
        Button("Add Loaded Objects") {
          applyLoadedMarkers(replacingExisting: false)
        }
        Button("Cancel", role: .cancel) {
          clearPendingLoad()
        }
      } message: {
        Text("Objects already exist in the current session. Do you want to replace them or add the loaded objects?")
      }
      .fileImporter(
        isPresented: $showLoadFilePicker,
        allowedContentTypes: [.borgVRMarker],
        allowsMultipleSelection: false
      ) { result in
        loadMarkers(from: result)
      }
      .fileExporter(
        isPresented: $showSaveFilePicker,
        document: VolumeMarkerDocument(
          datasetID: currentDatasetID,
          markers: appModel.volumeMarkers,
          meshInstances: appModel.sceneMeshInstances
        ),
        contentType: .borgVRMarker,
        defaultFilename: BorgVRMarkerFormat.defaultFilename
      ) { result in
        do {
          try VolumeMarkerExportRecovery.finish(
            result,
            datasetID: currentDatasetID,
            markers: appModel.volumeMarkers,
            meshInstances: appModel.sceneMeshInstances
          )
          refreshMarkerCatalog()
        } catch {
          markerFileError = error
          showMarkerFileError = true
        }
      }
      .fileDialogDefaultDirectory(markerStorageDirectoryURL)
      .alert(
        "Object File Error",
        isPresented: $showMarkerFileError,
        presenting: markerFileError
      ) { _ in
        Button("OK", role: .cancel) {
          showMarkerFileError = false
        }
      } message: { error in
        Text(error.localizedDescription)
      }
      .onAppear(perform: refreshMarkerCatalog)
      .onReceive(NotificationCenter.default.publisher(for: VolumeMarkerCatalog.didChangeNotification)) { _ in
        refreshMarkerCatalog()
      }
      .onChange(of: currentDatasetID) { _, _ in
        refreshMarkerCatalog()
      }
    }
  }

  private var currentDatasetID: String? { appModel.activeDataset?.uniqueId }

  private var markerStorageDirectoryURL: URL? {
    VolumeMarkerCatalog.storageDirectoryURL(logger: appModel.logger)
  }

  private var selectedSceneObject: SceneMeshInstance? {
    guard let selectedID = appModel.selectedSceneMeshInstanceID else { return nil }
    return appModel.sceneMeshInstances.first { $0.id == selectedID }
  }

  private var selectedMarkersTitle: LocalizedStringKey {
    selectedMarkerIndices.count == 1 ? "Selected Object" : "Selected Objects"
  }

  private var deleteSelectedMarkersTitle: LocalizedStringKey {
    selectedMarkerIndices.count == 1 ? "Delete Selected Object" : "Delete Selected Objects"
  }

  private var selectedMarkerIndex: Int? {
    guard let id = appModel.selectedVolumeMarkerID else { return nil }
    return appModel.volumeMarkers.firstIndex { $0.id == id }
  }

  private var selectedMarkerIndices: [Int] {
    appModel.volumeMarkers.indices.filter {
      appModel.selectedVolumeMarkerIDs.contains(appModel.volumeMarkers[$0].id)
    }
  }

  private var selectedNameBinding: Binding<String> {
    Binding(
      get: {
        guard let index = selectedMarkerIndex else { return "" }
        return appModel.volumeMarkers[index].name
      },
      set: { name in
        guard let index = selectedMarkerIndex else { return }
        appModel.volumeMarkers[index].name = String(
          name.prefix(BorgVRMarkerFormat.maximumNameCharacterCount)
        )
        synchronizeMarkers()
      }
    )
  }

  private var selectedColorBinding: Binding<Color> {
    Binding(
      get: {
        guard let index = selectedMarkerIndex else { return .red }
        return color(from: appModel.volumeMarkers[index].color)
      },
      set: { newColor in
        let markerColor = simdColor(from: newColor)
        for index in selectedMarkerIndices {
          appModel.volumeMarkers[index].color = markerColor
        }
        synchronizeMarkers()
      }
    )
  }

  private var selectedRadiusBinding: Binding<Float> {
    Binding(
      get: {
        guard let index = selectedMarkerIndex else {
          return VolumeMarkerRadius.sphereDefault
        }
        return appModel.volumeMarkers[index].radius
      },
      set: { radius in
        guard let index = selectedMarkerIndex else { return }
        let previousRadius = max(appModel.volumeMarkers[index].radius, 0.000_001)
        let factor = radius / previousRadius
        for selectedIndex in selectedMarkerIndices {
          appModel.volumeMarkers[selectedIndex].scaleRadii(by: factor)
        }
        if appModel.volumeMarkers[index].kind == .sphere {
          appModel.defaultVolumeMarkerRadius = appModel.volumeMarkers[index].radius
        }
        synchronizeMarkers()
      }
    )
  }

  private var selectedRadiusRange: ClosedRange<Float> {
    guard let primaryIndex = selectedMarkerIndex else {
      return VolumeMarkerRadius.sphereRange
    }
    let primaryRadius = max(appModel.volumeMarkers[primaryIndex].radius, 0.000_001)
    var lowerFactor: Float = 0
    var upperFactor = Float.greatestFiniteMagnitude
    for index in selectedMarkerIndices {
      let marker = appModel.volumeMarkers[index]
      let range = VolumeMarkerRadius.range(for: marker.kind)
      let radius = max(marker.radius, 0.000_001)
      lowerFactor = max(lowerFactor, range.lowerBound / radius)
      upperFactor = min(upperFactor, range.upperBound / radius)
    }
    return (primaryRadius * lowerFactor)...(primaryRadius * upperFactor)
  }

  private var selectionContainsSphere: Bool {
    appModel.volumeMarkers.contains {
      appModel.selectedVolumeMarkerIDs.contains($0.id) && $0.kind == .sphere
    }
  }

  private var selectedDirectionBinding: Binding<Bool> {
    Binding(
      get: {
        let selectedSpheres = appModel.volumeMarkers.filter {
          appModel.selectedVolumeMarkerIDs.contains($0.id) && $0.kind == .sphere
        }
        return !selectedSpheres.isEmpty && selectedSpheres.allSatisfy(\.showsDirection)
      },
      set: { showsDirection in
        for index in appModel.volumeMarkers.indices
          where appModel.selectedVolumeMarkerIDs.contains(appModel.volumeMarkers[index].id) &&
          appModel.volumeMarkers[index].kind == .sphere {
          appModel.volumeMarkers[index].showsDirection = showsDirection
        }
        appModel.defaultVolumeMarkerShowsDirection = showsDirection
        synchronizeMarkers()
      }
    )
  }

  private func deleteSelectedMarker() {
    let selectedIDs = appModel.selectedVolumeMarkerIDs
    let removedMarkers = appModel.removeVolumeMarkers(withIDs: selectedIDs)
    let removedObject: Bool
    if let instanceID = appModel.selectedSceneMeshInstanceID {
      removedObject = appModel.removeSceneMeshInstance(id: instanceID)
    } else {
      removedObject = false
    }
    if removedMarkers || removedObject {
      synchronizeMarkers()
    }
  }

  private func loadMarkers(from result: Result<[URL], Error>) {
    do {
      guard let url = try result.get().first else { return }
      let hasSecurityScope = url.startAccessingSecurityScopedResource()
      defer {
        if hasSecurityScope {
          url.stopAccessingSecurityScopedResource()
        }
      }

      prepareLoadedMarkers(try VolumeMarkerDocument.decode(from: Data(contentsOf: url)))
    } catch {
      markerFileError = error
      showMarkerFileError = true
    }
  }

  private func loadMarkers(at url: URL) {
    do {
      prepareLoadedMarkers(try VolumeMarkerDocument.decode(from: Data(contentsOf: url, options: .mappedIfSafe)))
    } catch {
      markerFileError = error
      showMarkerFileError = true
    }
  }

  private func prepareLoadedMarkers(_ contents: VolumeMarkerDocumentContents) {
    pendingLoadedMarkers = contents.markers
    pendingLoadedMeshInstances = contents.meshInstances
    if let currentDatasetID,
       contents.datasetID.caseInsensitiveCompare(currentDatasetID) != .orderedSame {
      showDatasetMismatchWarning = true
    } else {
      continueLoadingMarkers()
    }
  }

  private func continueLoadingMarkers() {
    if appModel.volumeMarkers.isEmpty && appModel.sceneMeshInstances.isEmpty {
      applyLoadedMarkers(replacingExisting: true)
    } else {
      showLoadMergeChoice = true
    }
  }

  private func clearPendingLoad() {
    pendingLoadedMarkers = []
    pendingLoadedMeshInstances = []
  }

  private func applyLoadedMarkers(replacingExisting: Bool) {
    if replacingExisting {
      appModel.volumeMarkers = pendingLoadedMarkers
      appModel.replaceSceneMeshInstances(pendingLoadedMeshInstances)
    } else {
      appModel.volumeMarkers.append(contentsOf: markersWithUniqueIDs(pendingLoadedMarkers))
      appModel.sceneMeshInstances.append(
        contentsOf: meshInstancesWithUniqueIDs(pendingLoadedMeshInstances)
      )
    }
    appModel.resolveSceneMeshAssets()
    clearPendingLoad()
    appModel.selectedVolumeMarkerID = nil
    synchronizeMarkers()
  }

  private func markersWithUniqueIDs(_ markers: [VolumeMarker]) -> [VolumeMarker] {
    var usedIDs = Set(appModel.volumeMarkers.map(\.id))
    return markers.map { marker in
      var marker = marker
      if usedIDs.contains(marker.id) {
        marker.id = UUID()
      }
      usedIDs.insert(marker.id)
      return marker
    }
  }

  private func meshInstancesWithUniqueIDs(
    _ instances: [SceneMeshInstance]
  ) -> [SceneMeshInstance] {
    var usedIDs = Set(appModel.sceneMeshInstances.map(\.id))
    return instances.map { instance in
      var instance = instance
      if usedIDs.contains(instance.id) {
        instance.id = UUID()
      }
      usedIDs.insert(instance.id)
      return instance
    }
  }

  private func synchronizeMarkers() {
    sharePlay.synchronizeMarkers()
  }

  private func refreshMarkerCatalog() {
    let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    markerCatalog = VolumeMarkerCatalog.entries(
      additionalDirectoryURLs: documentsURL.map { [$0] } ?? [],
      currentDatasetID: currentDatasetID,
      logger: appModel.logger
    )
  }

  private func color(from value: SIMD4<Float>) -> Color {
    Color(
      red: Double(value.x),
      green: Double(value.y),
      blue: Double(value.z),
      opacity: Double(value.w)
    )
  }

  private func simdColor(from color: Color) -> SIMD4<Float> {
    let uiColor = UIColor(color)
    var red: CGFloat = 1
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 1
    uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return SIMD4<Float>(Float(red), Float(green), Float(blue), 1)
  }
}
