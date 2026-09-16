import SwiftUI
import UIKit

struct MarkerView: View {
  @Environment(RuntimeAppModel.self) private var runtimeAppModel
  @Environment(SharedAppModel.self) private var sharedAppModel
  @EnvironmentObject var storedAppModel: StoredAppModel

  @State private var showClearAllConfirmation = false

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
}
