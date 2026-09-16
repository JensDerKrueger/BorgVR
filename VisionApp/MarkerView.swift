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
        List(selection: selectedMarkerBinding) {
          ForEach(sharedAppModel.volumeMarkers) { marker in
            HStack {
              Circle()
                .fill(color(from: marker.color))
                .frame(width: 18, height: 18)
              Text(marker.name)
              Spacer()
            }
            .tag(marker.id)
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
        } else {
          Text("private_marker_no_selection")
            .foregroundStyle(.secondary)
        }

        HStack {
          Button("marker_load_button") {
            showLoadFilePicker = true
          }

          Button("marker_save_button") {
            showSaveFilePicker = true
          }
          .disabled(sharedAppModel.volumeMarkers.isEmpty)
        }

        HStack {
          Button("private_marker_delete_selected_button") {
            deleteSelectedMarker()
          }
          .disabled(sharedAppModel.selectedVolumeMarkerID == nil)

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
        pendingLoadedMarkers = []
      }
    } message: {
      Text("marker_load_merge_message")
    }
    .fileImporter(
      isPresented: $showLoadFilePicker,
      allowedContentTypes: [.json],
      allowsMultipleSelection: false
    ) { result in
      loadMarkers(from: result)
    }
    .fileExporter(
      isPresented: $showSaveFilePicker,
      document: VolumeMarkerDocument(markers: sharedAppModel.volumeMarkers),
      contentType: .json,
      defaultFilename: "BorgVR Markers.json"
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

  private var selectedMarkerBinding: Binding<UUID?> {
    Binding(
      get: { sharedAppModel.selectedVolumeMarkerID },
      set: { newValue in
        sharedAppModel.selectedVolumeMarkerID = newValue
      }
    )
  }

  private var selectedMarkerNameBinding: Binding<String>? {
    guard let markerID = sharedAppModel.selectedVolumeMarkerID,
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
        sharedAppModel.volumeMarkers[currentIndex].name = String(newName.prefix(80))
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
        guard let currentIndex = sharedAppModel.volumeMarkers.firstIndex(where: { $0.id == markerID }) else {
          return
        }
        sharedAppModel.volumeMarkers[currentIndex].color = simdColor(from: newColor)
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

  private func deleteSelectedMarker() {
    guard let markerID = sharedAppModel.selectedVolumeMarkerID else {
      return
    }
    sharedAppModel.volumeMarkers.removeAll { $0.id == markerID }
    sharedAppModel.selectedVolumeMarkerID = nil
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

      let data = try Data(contentsOf: url)
      let markers = try VolumeMarkerDocument.decodeMarkers(from: data)
      pendingLoadedMarkers = markers

      if sharedAppModel.volumeMarkers.isEmpty {
        applyLoadedMarkers(replacingExisting: true)
      } else {
        showLoadMergeChoice = true
      }
    } catch {
      markerFileError = error
      showMarkerFileError = true
    }
  }

  private func applyLoadedMarkers(replacingExisting: Bool) {
    if replacingExisting {
      sharedAppModel.volumeMarkers = pendingLoadedMarkers
    } else {
      sharedAppModel.volumeMarkers.append(contentsOf: markersWithUniqueIDs(pendingLoadedMarkers))
    }
    pendingLoadedMarkers = []
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
}

private struct VolumeMarkerDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.json] }
  static var writableContentTypes: [UTType] { [.json] }

  let markers: [VolumeMarker]

  init(markers: [VolumeMarker]) {
    self.markers = markers
  }

  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents else {
      throw CocoaError(.fileReadCorruptFile)
    }
    markers = try Self.decodeMarkers(from: data)
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    let payload = VolumeMarkerFile(markers: markers.map(StoredVolumeMarker.init(marker:)))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return .init(regularFileWithContents: try encoder.encode(payload))
  }

  static func decodeMarkers(from data: Data) throws -> [VolumeMarker] {
    let decoder = JSONDecoder()
    let payload = try decoder.decode(VolumeMarkerFile.self, from: data)
    return payload.markers.map(\.marker)
  }
}

private struct VolumeMarkerFile: Codable {
  var format: String = "BorgVRVolumeMarkers"
  var version: Int = 1
  var markers: [StoredVolumeMarker]
}

private struct StoredVolumeMarker: Codable {
  var id: UUID
  var name: String
  var position: [Float]
  var radius: Float
  var color: [Float]

  init(marker: VolumeMarker) {
    id = marker.id
    name = marker.name
    position = [marker.position.x, marker.position.y, marker.position.z]
    radius = marker.radius
    color = [marker.color.x, marker.color.y, marker.color.z, marker.color.w]
  }

  var marker: VolumeMarker {
    VolumeMarker(
      id: id,
      name: name,
      position: SIMD3<Float>(
        position[safe: 0] ?? 0.5,
        position[safe: 1] ?? 0.5,
        position[safe: 2] ?? 0.5
      ),
      radius: radius,
      color: SIMD4<Float>(
        color[safe: 0] ?? 1,
        color[safe: 1] ?? 0,
        color[safe: 2] ?? 0,
        color[safe: 3] ?? 1
      )
    )
  }
}

private extension Array {
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
