import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MacMarkerView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var sharePlay: SharePlayCoordinator
  @EnvironmentObject private var storedAppModel: StoredAppModel
  @State private var confirmDeleteAll = false
  @State private var showLoadFilePicker = false
  @State private var showSaveFilePicker = false
  @State private var pendingLoadedMarkers: [VolumeMarker] = []
  @State private var showLoadMergeChoice = false
  @State private var showDatasetMismatchWarning = false
  @State private var markerCatalog: [VolumeMarkerCatalogEntry] = []
  @State private var markerFileError: Error?
  @State private var showMarkerFileError = false

  var body: some View {
    VStack(spacing: 16) {
      if appModel.volumeMarkers.isEmpty {
        ContentUnavailableView(
          "No Markers",
          systemImage: "mappin.slash",
          description: Text("Choose the Marker interaction mode and click in the rendering view to add a marker.")
        )
        .frame(maxHeight: .infinity)
      } else {
        List(selection: selectionBinding) {
          ForEach(appModel.volumeMarkers) { marker in
            HStack {
              Circle()
                .fill(color(from: marker.color))
                .frame(width: 14, height: 14)
              VStack(alignment: .leading, spacing: 1) {
                Text(marker.name)
                  .lineLimit(1)
                Text(
                  marker.kind == .sphere
                    ? String(localized: "Sphere")
                    : String(localized: "Stroke")
                )
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            .tag(marker.id)
          }
        }
        .frame(minHeight: 180)

        if !selectedMarkerIndices.isEmpty {
          Form {
            if selectedMarkerIndices.count == 1 {
              TextField("Name", text: selectedNameBinding)
            }
            ColorPicker("Color", selection: selectedColorBinding, supportsOpacity: false)
            HStack {
              Text("Radius")
              Slider(value: selectedRadiusBinding, in: selectedRadiusRange)
              Text(selectedRadiusBinding.wrappedValue, format: .number.precision(.fractionLength(3)))
                .monospacedDigit()
                .frame(width: 54, alignment: .trailing)
            }
            if selectionContainsSphere {
              Toggle("Show Direction", isOn: selectedDirectionBinding)
            }
          }
          .formStyle(.grouped)
        }
      }

      HStack {
        Menu {
          if markerCatalog.isEmpty {
            Text("No Marker Files Available")
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
          Label("Marker Files", systemImage: "mappin.and.ellipse")
        }

        Button {
          showLoadFilePicker = true
        } label: {
          Label("Load Markers…", systemImage: "folder")
        }

        Button {
          showSaveFilePicker = true
        } label: {
          Label("Save Markers…", systemImage: "square.and.arrow.down")
        }
        .disabled(appModel.volumeMarkers.isEmpty)

        Spacer()
      }

      HStack {
        Button(role: .destructive) {
          deleteSelectedMarker()
        } label: {
          Label(
            deleteSelectedMarkersTitle,
            systemImage: "trash"
          )
        }
        .disabled(selectedMarkerIndices.isEmpty)

        Spacer()

        Button(role: .destructive) {
          confirmDeleteAll = true
        } label: {
          Label("Delete All Markers", systemImage: "trash.slash")
        }
        .disabled(appModel.volumeMarkers.isEmpty)
      }
    }
    .padding(20)
    .confirmationDialog(
      "Delete All Markers?",
      isPresented: $confirmDeleteAll,
      titleVisibility: .visible
    ) {
      Button("Delete All Markers", role: .destructive) {
        if appModel.removeAllVolumeMarkers() {
          synchronizeMarkers()
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This removes every marker from the current session.")
    }
    .confirmationDialog(
      "Markers for a Different Dataset",
      isPresented: $showDatasetMismatchWarning,
      titleVisibility: .visible
    ) {
      Button("Load Anyway") {
        continueLoadingMarkers()
      }
      Button("Cancel", role: .cancel) {
        clearPendingLoad()
      }
    } message: {
      Text("This marker file was created for a different dataset. Its positions may not match the current volume. Do you still want to load it?")
    }
    .confirmationDialog(
      "Load Markers",
      isPresented: $showLoadMergeChoice,
      titleVisibility: .visible
    ) {
      Button("Replace Existing Markers", role: .destructive) {
        applyLoadedMarkers(replacingExisting: true)
      }
      Button("Add Loaded Markers") {
        applyLoadedMarkers(replacingExisting: false)
      }
      Button("Cancel", role: .cancel) {
        clearPendingLoad()
      }
    } message: {
      Text("Markers already exist in the current session. Do you want to replace them or add the loaded markers?")
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
      document: VolumeMarkerDocument(datasetID: currentDatasetID, markers: appModel.volumeMarkers),
      contentType: .borgVRMarker,
      defaultFilename: BorgVRMarkerFormat.defaultFilename
    ) { result in
      if case let .failure(error) = result {
        markerFileError = error
        showMarkerFileError = true
      }
    }
    .alert(
      "Marker File Error",
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

  private var currentDatasetID: String? { appModel.activeDataset?.uniqueId }

  private var deleteSelectedMarkersTitle: LocalizedStringKey {
    selectedMarkerIndices.count == 1 ? "Delete Selected Marker" : "Delete Selected Markers"
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

  private var selectionBinding: Binding<Set<UUID>> {
    Binding(
      get: { appModel.selectedVolumeMarkerIDs },
      set: { markerIDs in
        appModel.setVolumeMarkerSelection(markerIDs)
        if !markerIDs.isEmpty {
          appModel.interactionMode = .marker
        }
      }
    )
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
    if appModel.removeVolumeMarkers(withIDs: selectedIDs) {
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
    if let currentDatasetID,
       contents.datasetID.caseInsensitiveCompare(currentDatasetID) != .orderedSame {
      showDatasetMismatchWarning = true
    } else {
      continueLoadingMarkers()
    }
  }

  private func continueLoadingMarkers() {
    if appModel.volumeMarkers.isEmpty {
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
      appModel.volumeMarkers = pendingLoadedMarkers
    } else {
      appModel.volumeMarkers.append(contentsOf: markersWithUniqueIDs(pendingLoadedMarkers))
    }
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

  private func synchronizeMarkers() {
    sharePlay.synchronizeMarkers()
  }

  private func refreshMarkerCatalog() {
    markerCatalog = VolumeMarkerCatalog.entries(
      additionalDirectoryURLs: [storedAppModel.resolvedDataDirectoryURL()],
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
    let nsColor = NSColor(color).usingColorSpace(.deviceRGB) ?? .red
    return SIMD4<Float>(
      Float(nsColor.redComponent),
      Float(nsColor.greenComponent),
      Float(nsColor.blueComponent),
      1
    )
  }
}
