import GameController
import SwiftUI

enum SpatialControllerFaceButton: String, CaseIterable, Hashable, Sendable {
  case a
  case b
  case x
  case y

  var inputName: GCButtonElementName {
    switch self {
      case .a: .a
      case .b: .b
      case .x: .x
      case .y: .y
    }
  }

  var fallbackName: String {
    rawValue.uppercased()
  }

  var fallbackSystemImage: String {
    "\(rawValue).circle"
  }

  func presentation(controllers: [GCController] = GCController.controllers()) -> (
    name: String,
    systemImage: String
  ) {
    let element = controllers
      .filter { $0.productCategory == GCProductCategorySpatialController }
      .compactMap { $0.input.buttons[inputName] }
      .first
    return (
      element?.localizedName ?? fallbackName,
      element?.sfSymbolsName ?? fallbackSystemImage
    )
  }
}

enum SpatialControllerButtonAction: String, CaseIterable, Identifiable {
  enum Category: CaseIterable {
    case general
    case interaction
    case rendering
    case windows
    case actions

    var title: String {
      switch self {
        case .general: String(localized: "controller_action_category_general")
        case .interaction: String(localized: "controller_action_category_interaction")
        case .rendering: String(localized: "controller_action_category_rendering")
        case .windows: String(localized: "controller_action_category_windows")
        case .actions: String(localized: "controller_action_category_actions")
      }
    }
  }

  case none
  case nextInteractionMode
  case modelMode
  case clippingMode
  case markerMode
  case screenViewMode
  case nextRenderMode
  case transferFunctionLightingMode
  case transferFunctionMode
  case isoValueMode
  case toggleCurrentEditor
  case toggleMarkerWindow
  case toggleLightingWindow
  case toggleInteractionWindow
  case resetModel
  case resetClipping
  case deleteSelectedMarkers
  case toggleSelectedMarkerDirections

  var id: String { rawValue }

  var category: Category {
    switch self {
      case .none:
        .general
      case .nextInteractionMode, .modelMode, .clippingMode, .markerMode, .screenViewMode:
        .interaction
      case .nextRenderMode, .transferFunctionLightingMode, .transferFunctionMode, .isoValueMode:
        .rendering
      case .toggleCurrentEditor, .toggleMarkerWindow, .toggleLightingWindow,
           .toggleInteractionWindow:
        .windows
      case .resetModel, .resetClipping, .deleteSelectedMarkers,
           .toggleSelectedMarkerDirections:
        .actions
    }
  }

  var title: String {
    switch self {
      case .none: String(localized: "controller_action_none")
      case .nextInteractionMode: String(localized: "controller_action_next_interaction_mode")
      case .modelMode: String(localized: "controller_action_model_mode")
      case .clippingMode: String(localized: "controller_action_clipping_mode")
      case .markerMode: String(localized: "controller_action_marker_mode")
      case .screenViewMode: String(localized: "controller_action_screen_view_mode")
      case .nextRenderMode: String(localized: "controller_action_next_render_mode")
      case .transferFunctionLightingMode:
        String(localized: "controller_action_tf_lighting_mode")
      case .transferFunctionMode: String(localized: "controller_action_tf_mode")
      case .isoValueMode: String(localized: "controller_action_iso_mode")
      case .toggleCurrentEditor: String(localized: "controller_action_toggle_current_editor")
      case .toggleMarkerWindow: String(localized: "controller_action_toggle_marker_window")
      case .toggleLightingWindow: String(localized: "controller_action_toggle_lighting_window")
      case .toggleInteractionWindow:
        String(localized: "controller_action_toggle_interaction_window")
      case .resetModel: String(localized: "controller_action_reset_model")
      case .resetClipping: String(localized: "controller_action_reset_clipping")
      case .deleteSelectedMarkers:
        String(localized: "controller_action_delete_selected_markers")
      case .toggleSelectedMarkerDirections:
        String(localized: "controller_action_toggle_marker_directions")
    }
  }

  var systemImage: String {
    switch self {
      case .none: "slash.circle"
      case .nextInteractionMode: "hand.tap"
      case .modelMode: "move.3d"
      case .clippingMode: "crop"
      case .markerMode: "mappin"
      case .screenViewMode: "rectangle.on.rectangle"
      case .nextRenderMode: "rectangle.3.group"
      case .transferFunctionLightingMode: "lightbulb"
      case .transferFunctionMode: "chart.xyaxis.line"
      case .isoValueMode: "square.3.layers.3d.top.filled"
      case .toggleCurrentEditor: "slider.horizontal.3"
      case .toggleMarkerWindow: "mappin.and.ellipse"
      case .toggleLightingWindow: "lightbulb.max"
      case .toggleInteractionWindow: "hand.draw"
      case .resetModel: "arrow.counterclockwise"
      case .resetClipping: "crop.rotate"
      case .deleteSelectedMarkers: "trash"
      case .toggleSelectedMarkerDirections: "location.north.line"
    }
  }

  static func actions(in category: Category) -> [Self] {
    allCases.filter { $0.category == category }
  }
}

@MainActor
enum SpatialControllerShortcutHandler {
  static func perform(
    _ action: SpatialControllerButtonAction,
    runtimeAppModel: RuntimeAppModel,
    sharedAppModel: SharedAppModel
  ) {
    switch action {
      case .none:
        break
      case .nextInteractionMode:
        var modes: [RuntimeAppModel.InteractionMode] = [.model, .clipping, .marker]
        if hasSharedScreenView(sharedAppModel) {
          modes.append(.screenView)
        }
        let currentIndex = modes.firstIndex(of: runtimeAppModel.interactionMode) ?? -1
        setInteractionMode(
          modes[(currentIndex + 1) % modes.count],
          runtimeAppModel: runtimeAppModel,
          sharedAppModel: sharedAppModel
        )
      case .modelMode:
        setInteractionMode(.model, runtimeAppModel: runtimeAppModel, sharedAppModel: sharedAppModel)
      case .clippingMode:
        setInteractionMode(.clipping, runtimeAppModel: runtimeAppModel, sharedAppModel: sharedAppModel)
      case .markerMode:
        setInteractionMode(.marker, runtimeAppModel: runtimeAppModel, sharedAppModel: sharedAppModel)
      case .screenViewMode:
        guard hasSharedScreenView(sharedAppModel) else { return }
        setInteractionMode(.screenView, runtimeAppModel: runtimeAppModel, sharedAppModel: sharedAppModel)
      case .nextRenderMode:
        let modes: [RenderMode] = [
          .transferFunction1DLighting,
          .transferFunction1D,
          .isoValue
        ]
        let currentIndex = modes.firstIndex(of: sharedAppModel.renderMode) ?? -1
        setRenderMode(modes[(currentIndex + 1) % modes.count], sharedAppModel: sharedAppModel)
      case .transferFunctionLightingMode:
        setRenderMode(.transferFunction1DLighting, sharedAppModel: sharedAppModel)
      case .transferFunctionMode:
        setRenderMode(.transferFunction1D, sharedAppModel: sharedAppModel)
      case .isoValueMode:
        setRenderMode(.isoValue, sharedAppModel: sharedAppModel)
      case .toggleCurrentEditor:
        let isIso = sharedAppModel.renderMode == .isoValue
        runtimeAppModel.requestAuxiliaryWindowToggle(
          isIso ? "IsovalueEditorView" : "TransferFunctionEditorView",
          mutuallyExclusiveWith: isIso ? "TransferFunctionEditorView" : "IsovalueEditorView"
        )
      case .toggleMarkerWindow:
        runtimeAppModel.requestAuxiliaryWindowToggle("MarkerView")
      case .toggleLightingWindow:
        runtimeAppModel.requestAuxiliaryWindowToggle("LightingEditorView")
      case .toggleInteractionWindow:
        runtimeAppModel.requestAuxiliaryWindowToggle("PrivateApplicationView")
      case .resetModel:
        sharedAppModel.resetModel()
        sharedAppModel.synchronize(kind: .full)
      case .resetClipping:
        sharedAppModel.resetClipBoundsToVolume()
        sharedAppModel.synchronize(kind: .full)
      case .deleteSelectedMarkers:
        let selectedIDs = sharedAppModel.selectedVolumeMarkerIDs
        guard !selectedIDs.isEmpty else { return }
        sharedAppModel.volumeMarkers.removeAll { selectedIDs.contains($0.id) }
        sharedAppModel.clearVolumeMarkerSelection()
        sharedAppModel.synchronizeMarkers()
      case .toggleSelectedMarkerDirections:
        let indices = sharedAppModel.volumeMarkers.indices.filter {
          sharedAppModel.selectedVolumeMarkerIDs.contains(sharedAppModel.volumeMarkers[$0].id) &&
            sharedAppModel.volumeMarkers[$0].kind == .sphere
        }
        guard !indices.isEmpty else { return }
        let showDirections = !indices.allSatisfy {
          sharedAppModel.volumeMarkers[$0].showsDirection
        }
        for index in indices {
          sharedAppModel.volumeMarkers[index].showsDirection = showDirections
        }
        sharedAppModel.defaultVolumeMarkerShowsDirection = showDirections
        sharedAppModel.synchronizeMarkers()
    }
  }

  private static func hasSharedScreenView(_ sharedAppModel: SharedAppModel) -> Bool {
    sharedAppModel.screenSharePlayViewState != nil &&
      sharedAppModel.sharePlayParticipants.contains {
        $0.platform == .iOS || $0.platform == .macOS
      }
  }

  private static func setInteractionMode(
    _ mode: RuntimeAppModel.InteractionMode,
    runtimeAppModel: RuntimeAppModel,
    sharedAppModel: SharedAppModel
  ) {
    if mode != .marker {
      sharedAppModel.clearVolumeMarkerSelection()
    }
    runtimeAppModel.interactionMode = mode
  }

  private static func setRenderMode(_ mode: RenderMode, sharedAppModel: SharedAppModel) {
    sharedAppModel.renderMode = mode
    sharedAppModel.synchronize(kind: .stateOnly)
  }
}
