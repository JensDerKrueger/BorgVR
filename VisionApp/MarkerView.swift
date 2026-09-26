import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MarkerView: View {
  @Environment(RuntimeAppModel.self) private var runtimeAppModel
  @Environment(SharedAppModel.self) private var sharedAppModel
  @EnvironmentObject var storedAppModel: StoredAppModel

  @State private var showClearAllConfirmation = false
  @State private var showLoadFilePicker = false
  @State private var showSaveFilePicker = false
  @State private var pendingLoadedMarkers: [VolumeMarker] = []
  @State private var showLoadMergeChoice = false
  @State private var showDatasetMismatchWarning = false
  @State private var markerCatalog: [VolumeMarkerCatalogEntry] = []
  @State private var markerFileError: Error?
  @State private var showMarkerFileError = false

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("marker_window_title")
        .font(.title)
        .bold()
        .frame(maxWidth: .infinity, alignment: .center)

      Picker(
        "private_interaction_picker_label",
        selection: interactionModeBinding
      ) {
        Text("private_interaction_option_model").tag("model")
        Text("private_interaction_option_clipping").tag("clipping")
        Text("private_interaction_option_marker").tag("marker")
        if hasSharedScreenView {
          Text("Screen View").tag("screenView")
        }
      }
      .pickerStyle(.segmented)

      HStack {
        Text("private_marker_spawn_label")
        Picker(
          "private_marker_spawn_label",
          selection: markerSpawnBinding
        ) {
          Text("private_marker_spawn_hand").tag(false)
          Text("private_marker_spawn_gaze").tag(true)
        }
        .pickerStyle(.segmented)
      }

      if sharedAppModel.volumeMarkers.isEmpty {
        Text("marker_window_empty")
          .foregroundStyle(.secondary)
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
                  Text(
                    marker.kind == .sphere
                      ? String(localized: "Sphere")
                      : String(localized: "Stroke")
                  )
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
        }
        .frame(minHeight: 240)
      }

      Divider()

      VStack(alignment: .leading, spacing: 12) {
        if let selectedMarkerNameBinding {
          TextField("marker_window_name_field", text: selectedMarkerNameBinding)
            .textFieldStyle(.roundedBorder)
        }

        if let selectedMarkerColorBinding {
          ColorPicker(
            "private_marker_color_picker",
            selection: selectedMarkerColorBinding,
            supportsOpacity: false
          )

          HStack {
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
            Label("marker_catalog_button", systemImage: "mappin.and.ellipse")
          }

          Button("marker_load_button") {
            showLoadFilePicker = true
          }

          Button("marker_save_button") {
            showSaveFilePicker = true
          }
          .disabled(sharedAppModel.volumeMarkers.isEmpty)
        }

        HStack {
          Button(deleteSelectedMarkersTitle) {
            deleteSelectedMarkers()
          }
          .disabled(sharedAppModel.selectedVolumeMarkerIDs.isEmpty)

          Button("private_marker_clear_all_button") {
            showClearAllConfirmation = true
          }
          .disabled(sharedAppModel.volumeMarkers.isEmpty)
        }
        .padding(.bottom, 24)
      }
    }
    .padding()
    .confirmationDialog(
      "marker_clear_all_confirmation_title",
      isPresented: $showClearAllConfirmation,
      titleVisibility: .visible
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
    .fileExporter(
      isPresented: $showSaveFilePicker,
      document: VolumeMarkerDocument(datasetID: currentDatasetID, markers: sharedAppModel.volumeMarkers),
      contentType: .borgVRMarker,
      defaultFilename: BorgVRMarkerFormat.defaultFilename
    ) { result in
      if case let .failure(error) = result {
        markerFileError = error
        showMarkerFileError = true
      }
    }
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
    .onAppear(perform: refreshMarkerCatalog)
    .onReceive(NotificationCenter.default.publisher(for: VolumeMarkerCatalog.didChangeNotification)) { _ in
      refreshMarkerCatalog()
    }
    .onChange(of: currentDatasetID) { _, _ in
      refreshMarkerCatalog()
    }
  }

  private var currentDatasetID: String? { runtimeAppModel.activeDataset?.uniqueId }

  private var deleteSelectedMarkersTitle: LocalizedStringKey {
    sharedAppModel.selectedVolumeMarkerIDs.count == 1
      ? "private_marker_delete_selected_button"
      : "Delete Selected Markers"
  }

  private var hasSharedScreenView: Bool {
    sharedAppModel.screenSharePlayViewState != nil &&
      sharedAppModel.sharePlayParticipants.contains {
        $0.platform == .iOS || $0.platform == .macOS
      }
  }

  private var interactionModeBinding: Binding<String> {
    Binding(
      get: { runtimeAppModel.interactionMode.rawValue },
      set: { rawValue in
        if let newMode = RuntimeAppModel.InteractionMode(rawValue: rawValue) {
          if newMode != .marker {
            sharedAppModel.selectedVolumeMarkerID = nil
          }
          runtimeAppModel.interactionMode = newMode
        }
      }
    )
  }

  private var markerSpawnBinding: Binding<Bool> {
    Binding(
      get: { storedAppModel.markerSpawnAtGaze },
      set: { storedAppModel.markerSpawnAtGaze = $0 }
    )
  }

  private var selectedMarkerIndices: [Int] {
    sharedAppModel.volumeMarkers.indices.filter {
      sharedAppModel.selectedVolumeMarkerIDs.contains(sharedAppModel.volumeMarkers[$0].id)
    }
  }

  private func toggleSelection(of markerID: UUID) {
    var selection = sharedAppModel.selectedVolumeMarkerIDs
    if selection.contains(markerID) {
      selection.remove(markerID)
    } else {
      selection.insert(markerID)
    }
    sharedAppModel.setVolumeMarkerSelection(selection, primary: markerID)
    if !selection.isEmpty {
      runtimeAppModel.interactionMode = .marker
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
    let sphereIndices = selectedMarkerIndices.filter {
      sharedAppModel.volumeMarkers[$0].kind == .sphere
    }
    guard !sphereIndices.isEmpty else {
      return nil
    }

    return Binding(
      get: {
        sphereIndices.allSatisfy { sharedAppModel.volumeMarkers[$0].showsDirection }
      },
      set: { showsDirection in
        for index in selectedMarkerIndices where sharedAppModel.volumeMarkers[index].kind == .sphere {
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
    let selectedIDs = sharedAppModel.selectedVolumeMarkerIDs
    guard !selectedIDs.isEmpty else { return }
    sharedAppModel.volumeMarkers.removeAll { selectedIDs.contains($0.id) }
    sharedAppModel.clearVolumeMarkerSelection()
    sharedAppModel.synchronizeMarkers()
  }

  private func clearAllMarkers() {
    sharedAppModel.volumeMarkers.removeAll()
    sharedAppModel.selectedVolumeMarkerID = nil
    sharedAppModel.synchronizeMarkers()
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
    if let currentDatasetID,
       contents.datasetID.caseInsensitiveCompare(currentDatasetID) != .orderedSame {
      showDatasetMismatchWarning = true
    } else {
      continueLoadingMarkers()
    }
  }

  private func continueLoadingMarkers() {
    if sharedAppModel.volumeMarkers.isEmpty {
      applyLoadedMarkers(replacingExisting: true)
    } else {
      showLoadMergeChoice = true
    }
  }

  private func clearPendingLoad() {
    pendingLoadedMarkers = []
  }

  private func applyLoadedMarkers(replacingExisting: Bool) {
    if replacingExisting {
      sharedAppModel.volumeMarkers = pendingLoadedMarkers
    } else {
      sharedAppModel.volumeMarkers.append(contentsOf: markersWithUniqueIDs(pendingLoadedMarkers))
    }
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

  private func refreshMarkerCatalog() {
    let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    markerCatalog = VolumeMarkerCatalog.entries(
      additionalDirectoryURLs: documentsURL.map { [$0] } ?? [],
      currentDatasetID: currentDatasetID,
      logger: runtimeAppModel.logger
    )
  }
}
