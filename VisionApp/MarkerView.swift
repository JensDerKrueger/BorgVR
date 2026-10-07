import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MarkerView: View {
  @Environment(RuntimeAppModel.self) private var runtimeAppModel
  @Environment(SharedAppModel.self) private var sharedAppModel
  @EnvironmentObject var storedAppModel: StoredAppModel

  @State private var showClearAllConfirmation = false
  @State private var showLoadFilePicker = false
  @State private var pendingObjectExport: PendingSystemFileExport?
  @State private var pendingLoadedMarkers: [VolumeMarker] = []
  @State private var pendingLoadedMeshInstances: [SceneMeshInstance] = []
  @State private var showLoadMergeChoice = false
  @State private var showDatasetMismatchWarning = false
  @State private var markerCatalog: [VolumeMarkerCatalogEntry] = []
  @State private var markerFileError: Error?
  @State private var showMarkerFileError = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("marker_window_title")
        .font(.title2)
        .bold()
        .frame(maxWidth: .infinity, alignment: .center)

      HStack(alignment: .top, spacing: 18) {
        VStack(alignment: .leading, spacing: 12) {
          markerSpawnControls
          objectCatalog
          Divider()
          selectionControls
        }
        .frame(width: 410, alignment: .topLeading)

        Divider()

        VStack(alignment: .leading, spacing: 12) {
          objectList
          fileControls
          deleteControls
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    }
    .padding(20)
    .alert(
      "marker_clear_all_confirmation_title",
      isPresented: $showClearAllConfirmation
    ) {
      Button("marker_clear_all_confirmation_delete", role: .destructive) {
        clearAllMarkers()
      }
      Button("marker_clear_all_confirmation_cancel", role: .cancel) {}
    } message: {
      Text("marker_clear_all_confirmation_message")
    }
    .confirmationDialog(
      "marker_dataset_mismatch_title",
      isPresented: $showDatasetMismatchWarning,
      titleVisibility: .visible
    ) {
      Button("marker_dataset_mismatch_load") { continueLoadingMarkers() }
      Button("marker_clear_all_confirmation_cancel", role: .cancel) { clearPendingLoad() }
    } message: {
      Text("marker_dataset_mismatch_message")
    }
    .confirmationDialog(
      "marker_load_merge_title",
      isPresented: $showLoadMergeChoice,
      titleVisibility: .visible
    ) {
      Button("marker_load_replace_button", role: .destructive) {
        applyLoadedMarkers(replacingExisting: true)
      }
      Button("marker_load_add_button") {
        applyLoadedMarkers(replacingExisting: false)
      }
      Button("marker_clear_all_confirmation_cancel", role: .cancel) {
        clearPendingLoad()
      }
    } message: {
      Text("marker_load_merge_message")
    }
    .fileImporter(
      isPresented: $showLoadFilePicker,
      allowedContentTypes: [.borgVRMarker],
      allowsMultipleSelection: false
    ) { result in
      loadMarkers(from: result)
    }
    .sheet(item: $pendingObjectExport) { export in
      SystemFileExportPicker(
        sourceURL: export.sourceURL,
        defaultDirectoryURL: markerStorageDirectoryURL
      ) { exportedURL in
        export.removeTemporaryFiles()
        pendingObjectExport = nil
        if exportedURL != nil {
          NotificationCenter.default.post(
            name: VolumeMarkerCatalog.didChangeNotification,
            object: nil
          )
        }
        refreshMarkerCatalog()
      }
    }
    .fileDialogDefaultDirectory(markerStorageDirectoryURL)
    .alert(
      "marker_file_error_title",
      isPresented: $showMarkerFileError,
      presenting: markerFileError
    ) { _ in
      Button("tf_picker_ok_button", role: .cancel) {
        showMarkerFileError = false
      }
    } message: { error in
      Text(error.localizedDescription)
    }
    .onAppear {
      refreshMarkerCatalog()
      refreshMeshCatalog()
    }
    .onReceive(NotificationCenter.default.publisher(for: VolumeMarkerCatalog.didChangeNotification)) { _ in
      refreshMarkerCatalog()
    }
    .onReceive(NotificationCenter.default.publisher(for: SceneMeshAssetCatalog.didChangeNotification)) { _ in
      refreshMeshCatalog()
    }
    .onChange(of: currentDatasetID) { _, _ in
      refreshMarkerCatalog()
    }
  }

  private var currentDatasetID: String? { runtimeAppModel.activeDataset?.uniqueId }

  private var markerStorageDirectoryURL: URL? {
    VolumeMarkerCatalog.storageDirectoryURL(logger: runtimeAppModel.logger)
  }

  private var markerSpawnControls: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("private_marker_spawn_label")
        Picker("private_marker_spawn_label", selection: markerSpawnBinding) {
          Text("private_marker_spawn_hand").tag(false)
          Text("private_marker_spawn_gaze").tag(true)
        }
        .pickerStyle(.segmented)
      }
      Toggle("Snap to Volume", isOn: projectObjectsOntoVolumeBinding)
    }
  }

  private var objectCatalog: some View {
    SceneObjectCatalogView(
      assets: Binding(
        get: { sharedAppModel.sceneMeshAssets },
        set: { sharedAppModel.sceneMeshAssets = $0 }
      ),
      selectedPrototype: Binding(
        get: { sharedAppModel.selectedSceneObjectPrototype },
        set: { sharedAppModel.selectedSceneObjectPrototype = $0 }
      ),
      datasetExtentMeters: runtimeAppModel.activeDatasetInfo?.physicalExtentMeters,
      logger: runtimeAppModel.logger,
      additionalDirectoryURLs: FileManager.default.urls(
        for: .documentDirectory,
        in: .userDomainMask
      )
    )
  }

  @ViewBuilder
  private var objectList: some View {
    if sharedAppModel.volumeMarkers.isEmpty && sharedAppModel.sceneMeshInstances.isEmpty {
      ContentUnavailableView(
        "marker_window_empty",
        systemImage: "cube.transparent"
      )
      .frame(maxWidth: .infinity, minHeight: 210)
    } else {
      List {
        ForEach(sharedAppModel.volumeMarkers) { marker in
          Button {
            toggleSelection(of: marker.id)
          } label: {
            HStack {
              Circle()
                .fill(color(from: marker.color))
                .frame(width: 18, height: 18)
              VStack(alignment: .leading) {
                Text(marker.name)
                Text(markerKindName(marker.kind))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              if sharedAppModel.selectedVolumeMarkerIDs.contains(marker.id) {
                Image(systemName: "checkmark")
              }
            }
          }
          .buttonStyle(.plain)
        }
        ForEach(sharedAppModel.sceneMeshInstances) { instance in
          Button {
            sharedAppModel.selectedSceneMeshInstanceID = instance.id
            sharedAppModel.clearVolumeMarkerSelection()
            runtimeAppModel.interactionMode = .objectPlacement
          } label: {
            HStack {
              Image(systemName: "cube.fill")
                .frame(width: 18, height: 18)
              VStack(alignment: .leading) {
                Text(instance.name)
                Text(instance.asset.assetDescription.isEmpty
                  ? instance.asset.name
                  : instance.asset.assetDescription)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              if sharedAppModel.selectedSceneMeshInstanceID == instance.id {
                Image(systemName: "checkmark")
              }
            }
          }
          .buttonStyle(.plain)
        }
      }
      .frame(minHeight: 210)
    }
  }

  @ViewBuilder
  private var selectionControls: some View {
    if let selectedMarkerNameBinding {
      TextField("marker_window_name_field", text: selectedMarkerNameBinding)
        .textFieldStyle(.roundedBorder)
    }

    if let selectedMarkerColorBinding {
      HStack {
        ColorPicker(
          "private_marker_color_picker",
          selection: selectedMarkerColorBinding,
          supportsOpacity: false
        )
        Text("Radius")
        Slider(value: selectedMarkerRadiusBinding, in: selectedMarkerRadiusRange)
        Text(selectedMarkerRadiusBinding.wrappedValue, format: .number.precision(.fractionLength(3)))
          .monospacedDigit()
          .frame(width: 62, alignment: .trailing)
      }
    } else {
      Text("private_marker_no_selection")
        .foregroundStyle(.secondary)
    }

    if let selectedMarkerDirectionBinding {
      Toggle("Show Direction", isOn: selectedMarkerDirectionBinding)
    }
  }

  private var fileControls: some View {
    HStack {
      Menu {
        if markerCatalog.isEmpty {
          Text("marker_catalog_empty")
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
        Label("marker_catalog_button", systemImage: "shippingbox")
      }

      Button("marker_load_button") { showLoadFilePicker = true }

      Button("marker_save_button") { prepareObjectExport() }
        .disabled(sharedAppModel.volumeMarkers.isEmpty && sharedAppModel.sceneMeshInstances.isEmpty)
    }
  }

  private var deleteControls: some View {
    HStack {
      Button(deleteSelectedMarkersTitle) { deleteSelectedMarkers() }
        .disabled(
          sharedAppModel.selectedVolumeMarkerIDs.isEmpty &&
            sharedAppModel.selectedSceneMeshInstanceID == nil
        )

      Button("private_marker_clear_all_button") { showClearAllConfirmation = true }
        .disabled(sharedAppModel.volumeMarkers.isEmpty && sharedAppModel.sceneMeshInstances.isEmpty)
    }
  }

  private func markerKindName(_ kind: VolumeMarkerKind) -> String {
    switch kind {
      case .sphere:
        return String(localized: "Sphere")
      case .stroke:
        return String(localized: "Stroke")
    }
  }

  private var deleteSelectedMarkersTitle: LocalizedStringKey {
    sharedAppModel.selectedSceneMeshInstanceID != nil ||
      sharedAppModel.selectedVolumeMarkerIDs.count == 1
      ? "private_marker_delete_selected_button"
      : "Delete Selected Markers"
  }

  private func prepareObjectExport() {
    do {
      let data = try VolumeMarkerDocument.encode(
        datasetID: currentDatasetID,
        markers: sharedAppModel.volumeMarkers,
        meshInstances: sharedAppModel.sceneMeshInstances
      )
      pendingObjectExport = try PendingSystemFileExport(
        data: data,
        defaultFilename: BorgVRMarkerFormat.defaultFilename,
        temporaryDirectoryName: "BorgVRObjectExports"
      )
    } catch {
      markerFileError = error
      showMarkerFileError = true
    }
  }

  private var markerSpawnBinding: Binding<Bool> {
    Binding(
      get: { storedAppModel.markerSpawnAtGaze },
      set: { storedAppModel.markerSpawnAtGaze = $0 }
    )
  }

  private var projectObjectsOntoVolumeBinding: Binding<Bool> {
    Binding(
      get: { storedAppModel.projectObjectsOntoVolume },
      set: { storedAppModel.projectObjectsOntoVolume = $0 }
    )
  }

  private var selectedMarkerIndices: [Int] {
    sharedAppModel.volumeMarkers.indices.filter {
      sharedAppModel.selectedVolumeMarkerIDs.contains(sharedAppModel.volumeMarkers[$0].id)
    }
  }

  private func toggleSelection(of markerID: UUID) {
    sharedAppModel.selectedSceneMeshInstanceID = nil
    var selection = sharedAppModel.selectedVolumeMarkerIDs
    if selection.contains(markerID) {
      selection.remove(markerID)
    } else {
      selection.insert(markerID)
    }
    sharedAppModel.setVolumeMarkerSelection(selection, primary: markerID)
    if !selection.isEmpty {
      let marker = sharedAppModel.volumeMarkers.first { $0.id == markerID }
      runtimeAppModel.interactionMode = marker?.kind == .stroke ? .drawing : .objectPlacement
    }
  }

  private var selectedMarkerNameBinding: Binding<String>? {
    guard selectedMarkerIndices.count == 1,
          let markerID = sharedAppModel.selectedVolumeMarkerID,
          sharedAppModel.volumeMarkers.contains(where: { $0.id == markerID }) else {
      return nil
    }

    return Binding(
      get: {
        guard let currentIndex = sharedAppModel.volumeMarkers.firstIndex(where: { $0.id == markerID }) else {
          return ""
        }
        return sharedAppModel.volumeMarkers[currentIndex].name
      },
      set: { newName in
        guard let currentIndex = sharedAppModel.volumeMarkers.firstIndex(where: { $0.id == markerID }) else {
          return
        }
        sharedAppModel.volumeMarkers[currentIndex].name = String(
          newName.prefix(BorgVRMarkerFormat.maximumNameCharacterCount)
        )
        sharedAppModel.synchronizeMarkers()
      }
    )
  }

  private var selectedMarkerColorBinding: Binding<Color>? {
    guard let markerID = sharedAppModel.selectedVolumeMarkerID,
          sharedAppModel.volumeMarkers.contains(where: { $0.id == markerID }) else {
      return nil
    }

    return Binding(
      get: {
        guard let currentIndex = sharedAppModel.volumeMarkers.firstIndex(where: { $0.id == markerID }) else {
          return .red
        }
        return color(from: sharedAppModel.volumeMarkers[currentIndex].color)
      },
      set: { newColor in
        let markerColor = simdColor(from: newColor)
        for index in selectedMarkerIndices {
          sharedAppModel.volumeMarkers[index].color = markerColor
        }
        sharedAppModel.synchronizeMarkers()
      }
    )
  }

  private var selectedMarkerRadiusBinding: Binding<Float> {
    Binding(
      get: {
        guard let markerID = sharedAppModel.selectedVolumeMarkerID,
              let marker = sharedAppModel.volumeMarkers.first(where: { $0.id == markerID }) else {
          return VolumeMarkerRadius.sphereDefault
        }
        return marker.radius
      },
      set: { radius in
        guard let markerID = sharedAppModel.selectedVolumeMarkerID,
              let primaryIndex = sharedAppModel.volumeMarkers.firstIndex(where: { $0.id == markerID }) else {
          return
        }
        let previousRadius = max(sharedAppModel.volumeMarkers[primaryIndex].radius, 0.000_001)
        let factor = radius / previousRadius
        for index in selectedMarkerIndices {
          sharedAppModel.volumeMarkers[index].scaleRadii(by: factor)
        }
        let primaryMarker = sharedAppModel.volumeMarkers[primaryIndex]
        if primaryMarker.kind == .sphere {
          sharedAppModel.defaultVolumeMarkerRadius = primaryMarker.radius
        } else {
          sharedAppModel.defaultVolumeStrokeRadius = primaryMarker.radius
        }
        sharedAppModel.synchronizeMarkers()
      }
    )
  }

  private var selectedMarkerRadiusRange: ClosedRange<Float> {
    guard let markerID = sharedAppModel.selectedVolumeMarkerID,
          let primary = sharedAppModel.volumeMarkers.first(where: { $0.id == markerID }) else {
      return VolumeMarkerRadius.sphereRange
    }
    let primaryRadius = max(primary.radius, 0.000_001)
    var lowerFactor: Float = 0
    var upperFactor = Float.greatestFiniteMagnitude
    for index in selectedMarkerIndices {
      let marker = sharedAppModel.volumeMarkers[index]
      let range = VolumeMarkerRadius.range(for: marker.kind)
      let radius = max(marker.radius, 0.000_001)
      lowerFactor = max(lowerFactor, range.lowerBound / radius)
      upperFactor = min(upperFactor, range.upperBound / radius)
    }
    return (primaryRadius * lowerFactor)...(primaryRadius * upperFactor)
  }

  private var selectedMarkerDirectionBinding: Binding<Bool>? {
    let hasSelectedSphere = sharedAppModel.volumeMarkers.contains {
      sharedAppModel.selectedVolumeMarkerIDs.contains($0.id) && $0.kind == .sphere
    }
    guard hasSelectedSphere else {
      return nil
    }

    return Binding(
      get: {
        let selectedSpheres = sharedAppModel.volumeMarkers.filter {
          sharedAppModel.selectedVolumeMarkerIDs.contains($0.id) && $0.kind == .sphere
        }
        return !selectedSpheres.isEmpty && selectedSpheres.allSatisfy(\.showsDirection)
      },
      set: { showsDirection in
        for index in sharedAppModel.volumeMarkers.indices
          where sharedAppModel.selectedVolumeMarkerIDs.contains(
            sharedAppModel.volumeMarkers[index].id
          ) && sharedAppModel.volumeMarkers[index].kind == .sphere {
          sharedAppModel.volumeMarkers[index].showsDirection = showsDirection
        }
        sharedAppModel.defaultVolumeMarkerShowsDirection = showsDirection
        sharedAppModel.synchronizeMarkers()
      }
    )
  }

  private func color(from markerColor: SIMD4<Float>) -> Color {
    Color(
      red: Double(markerColor.x),
      green: Double(markerColor.y),
      blue: Double(markerColor.z),
      opacity: Double(markerColor.w)
    )
  }

  private func simdColor(from color: Color) -> SIMD4<Float> {
    var red: CGFloat = 1
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 1
    UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return SIMD4<Float>(
      Float(red),
      Float(green),
      Float(blue),
      Float(alpha)
    )
  }

  private func deleteSelectedMarkers() {
    if let meshID = sharedAppModel.selectedSceneMeshInstanceID {
      if sharedAppModel.removeSceneMeshInstance(id: meshID) {
        sharedAppModel.synchronizeMarkers()
      }
      return
    }
    let selectedIDs = sharedAppModel.selectedVolumeMarkerIDs
    if sharedAppModel.removeVolumeMarkers(withIDs: selectedIDs) {
      sharedAppModel.synchronizeMarkers()
    }
  }

  private func clearAllMarkers() {
    let removedMarkers = sharedAppModel.removeAllVolumeMarkers()
    let removedMeshes = !sharedAppModel.sceneMeshInstances.isEmpty
    sharedAppModel.sceneMeshInstances.removeAll()
    sharedAppModel.selectedSceneMeshInstanceID = nil
    if removedMarkers || removedMeshes {
      sharedAppModel.synchronizeMarkers()
    }
  }

  private func loadMarkers(from result: Result<[URL], Error>) {
    do {
      guard let url = try result.get().first else {
        return
      }

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
    if sharedAppModel.volumeMarkers.isEmpty && sharedAppModel.sceneMeshInstances.isEmpty {
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
      sharedAppModel.volumeMarkers = pendingLoadedMarkers
      sharedAppModel.replaceSceneMeshInstances(pendingLoadedMeshInstances)
    } else {
      sharedAppModel.volumeMarkers.append(contentsOf: markersWithUniqueIDs(pendingLoadedMarkers))
      sharedAppModel.sceneMeshInstances.append(
        contentsOf: meshInstancesWithUniqueIDs(pendingLoadedMeshInstances)
      )
    }
    sharedAppModel.resolveSceneMeshAssets()
    clearPendingLoad()
    sharedAppModel.selectedVolumeMarkerID = nil
    sharedAppModel.synchronizeMarkers()
  }

  private func markersWithUniqueIDs(_ markers: [VolumeMarker]) -> [VolumeMarker] {
    var usedIDs = Set(sharedAppModel.volumeMarkers.map(\.id))
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
    var usedIDs = Set(sharedAppModel.sceneMeshInstances.map(\.id))
    return instances.map { instance in
      var instance = instance
      if usedIDs.contains(instance.id) {
        instance.id = UUID()
      }
      usedIDs.insert(instance.id)
      return instance
    }
  }

  private func refreshMarkerCatalog() {
    let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    markerCatalog = VolumeMarkerCatalog.entries(
      additionalDirectoryURLs: documentsURL.map { [$0] } ?? [],
      currentDatasetID: currentDatasetID,
      logger: runtimeAppModel.logger
    )
  }

  private func refreshMeshCatalog() {
    sharedAppModel.refreshSceneMeshCatalog()
  }
}

struct PendingSystemFileExport: Identifiable {
  let id = UUID()
  let sourceURL: URL

  init(
    data: Data,
    defaultFilename: String,
    temporaryDirectoryName: String
  ) throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(temporaryDirectoryName, isDirectory: true)
      .appendingPathComponent(id.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
    sourceURL = directoryURL.appendingPathComponent(defaultFilename)
    try data.write(to: sourceURL, options: .atomic)
  }

  func removeTemporaryFiles() {
    try? FileManager.default.removeItem(at: sourceURL.deletingLastPathComponent())
  }
}

struct SystemFileExportPicker: UIViewControllerRepresentable {
  let sourceURL: URL
  let defaultDirectoryURL: URL?
  let completion: (URL?) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(completion: completion)
  }

  func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
    let picker = UIDocumentPickerViewController(
      forExporting: [sourceURL],
      asCopy: true
    )
    picker.directoryURL = defaultDirectoryURL
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(
    _ uiViewController: UIDocumentPickerViewController,
    context: Context
  ) {}

  final class Coordinator: NSObject, UIDocumentPickerDelegate {
    private let completion: (URL?) -> Void
    private var completed = false

    init(completion: @escaping (URL?) -> Void) {
      self.completion = completion
    }

    func documentPicker(
      _ controller: UIDocumentPickerViewController,
      didPickDocumentsAt urls: [URL]
    ) {
      finish(with: urls.first)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
      finish(with: nil)
    }

    private func finish(with url: URL?) {
      guard !completed else { return }
      completed = true
      completion(url)
    }
  }
}
