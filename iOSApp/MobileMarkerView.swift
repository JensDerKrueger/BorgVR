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
  @State private var showLoadMergeChoice = false
  @State private var showDatasetMismatchWarning = false
  @State private var markerCatalog: [VolumeMarkerCatalogEntry] = []
  @State private var markerFileError: Error?
  @State private var showMarkerFileError = false

  var body: some View {
    NavigationStack {
      Form {
        Section("Markers") {
          if appModel.volumeMarkers.isEmpty {
            ContentUnavailableView(
              "No Markers",
              systemImage: "mappin.slash",
              description: Text("Choose the Marker interaction mode and drag in the rendering view to add a marker.")
            )
          } else {
            ForEach(appModel.volumeMarkers) { marker in
              Button {
                appModel.selectedVolumeMarkerID = marker.id
                appModel.interactionMode = .marker
              } label: {
                HStack {
                  Circle()
                    .fill(color(from: marker.color))
                    .frame(width: 16, height: 16)
                  VStack(alignment: .leading, spacing: 1) {
                    Text(marker.name)
                      .foregroundStyle(.primary)
                    Text(marker.kind == .sphere ? "Sphere" : "Stroke")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                  Spacer()
                  if marker.id == appModel.selectedVolumeMarkerID {
                    Image(systemName: "checkmark")
                  }
                }
              }
            }
          }
        }

        if selectedMarkerIndex != nil {
          Section("Selected Marker") {
            TextField("Name", text: selectedNameBinding)
            ColorPicker("Color", selection: selectedColorBinding, supportsOpacity: false)
            LabeledContent("Radius") {
              Text(selectedRadiusBinding.wrappedValue, format: .number.precision(.fractionLength(3)))
                .monospacedDigit()
            }
            Slider(value: selectedRadiusBinding, in: selectedRadiusRange)

            if selectedMarkerKind == .sphere {
              Toggle("Show Direction", isOn: selectedDirectionBinding)
            }

            Button("Delete Selected Marker", role: .destructive) {
              deleteSelectedMarker()
            }
          }
        }

        Section("Marker Files") {
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
        }

        Section {
          Button("Delete All Markers", role: .destructive) {
            confirmDeleteAll = true
          }
          .disabled(appModel.volumeMarkers.isEmpty)
        }
      }
      .navigationTitle("Markers")
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
        "Delete All Markers?",
        isPresented: $confirmDeleteAll,
        titleVisibility: .visible
      ) {
        Button("Delete All Markers", role: .destructive) {
          appModel.volumeMarkers.removeAll()
          appModel.selectedVolumeMarkerID = nil
          synchronizeMarkers()
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
        Button("Load Anyway") { continueLoadingMarkers() }
        Button("Cancel", role: .cancel) { clearPendingLoad() }
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
  }

  private var currentDatasetID: String? { appModel.activeDataset?.uniqueId }

  private var selectedMarkerIndex: Int? {
    guard let id = appModel.selectedVolumeMarkerID else { return nil }
    return appModel.volumeMarkers.firstIndex { $0.id == id }
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
        guard let index = selectedMarkerIndex else { return }
        appModel.volumeMarkers[index].color = simdColor(from: newColor)
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
        let markerKind = appModel.volumeMarkers[index].kind
        let radius = VolumeMarkerRadius.clamp(
          radius,
          for: markerKind
        )
        appModel.volumeMarkers[index].radius = radius
        if markerKind == .sphere {
          appModel.defaultVolumeMarkerRadius = radius
        }
        synchronizeMarkers()
      }
    )
  }

  private var selectedRadiusRange: ClosedRange<Float> {
    guard let index = selectedMarkerIndex else {
      return VolumeMarkerRadius.sphereRange
    }
    return VolumeMarkerRadius.range(for: appModel.volumeMarkers[index].kind)
  }

  private var selectedMarkerKind: VolumeMarkerKind? {
    guard let index = selectedMarkerIndex else { return nil }
    return appModel.volumeMarkers[index].kind
  }

  private var selectedDirectionBinding: Binding<Bool> {
    Binding(
      get: {
        guard let index = selectedMarkerIndex else { return false }
        return appModel.volumeMarkers[index].showsDirection
      },
      set: { showsDirection in
        guard let index = selectedMarkerIndex,
              appModel.volumeMarkers[index].kind == .sphere else { return }
        appModel.volumeMarkers[index].showsDirection = showsDirection
        synchronizeMarkers()
      }
    )
  }

  private func deleteSelectedMarker() {
    guard let index = selectedMarkerIndex else { return }
    appModel.volumeMarkers.remove(at: index)
    appModel.selectedVolumeMarkerID = nil
    synchronizeMarkers()
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
