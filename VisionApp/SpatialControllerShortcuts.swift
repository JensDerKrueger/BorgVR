import GameController
import SwiftUI

enum SpatialToolMode: String, CaseIterable, Identifiable {
  case model
  case clipping
  case marker
  case objectPlacement
  case lengthMeasurement
  case areaMeasurement
  case volumeMeasurement
  case screenView

  static let museModes: [Self] = [
    .marker,
    .objectPlacement,
    .lengthMeasurement,
    .areaMeasurement,
    .volumeMeasurement
  ]

  var id: String { rawValue }

  var interactionMode: RuntimeAppModel.InteractionMode {
    switch self {
      case .model: .model
      case .clipping: .clipping
      case .marker: .drawing
      case .objectPlacement: .objectPlacement
      case .lengthMeasurement, .areaMeasurement, .volumeMeasurement: .measurement
      case .screenView: .screenView
    }
  }

  var measurementKind: VolumeMeasurementKind? {
    switch self {
      case .lengthMeasurement: .length
      case .areaMeasurement: .area
      case .volumeMeasurement: .volume
      default: nil
    }
  }

  var isMeasurement: Bool { measurementKind != nil }

  var title: String {
    switch self {
      case .model: String(localized: "accessory_tool_model")
      case .clipping: String(localized: "accessory_tool_clipping")
      case .marker: String(localized: "Draw")
      case .objectPlacement: String(localized: "Place Objects")
      case .lengthMeasurement: String(localized: "settings_stylus_start_length")
      case .areaMeasurement: String(localized: "settings_stylus_start_area")
      case .volumeMeasurement: String(localized: "settings_stylus_start_volume")
      case .screenView: String(localized: "controller_action_screen_view_mode")
    }
  }

  var systemImage: String {
    switch self {
      case .model: "move.3d"
      case .clipping: "crop"
      case .marker: "pencil.and.outline"
      case .objectPlacement: "cube.fill"
      case .lengthMeasurement: "ruler"
      case .areaMeasurement: "triangle"
      case .volumeMeasurement: "cube"
      case .screenView: "rectangle.on.rectangle"
    }
  }
}

enum SpatialStylusStartFunction: String, CaseIterable, Identifiable {
  case marker
  case objectPlacement
  case lengthMeasurement
  case areaMeasurement
  case volumeMeasurement
  case lastMode

  var id: String { rawValue }

  var title: String {
    switch self {
      case .marker: String(localized: "Draw")
      case .objectPlacement: String(localized: "Place Objects")
      case .lengthMeasurement: String(localized: "settings_stylus_start_length")
      case .areaMeasurement: String(localized: "settings_stylus_start_area")
      case .volumeMeasurement: String(localized: "settings_stylus_start_volume")
      case .lastMode: String(localized: "settings_stylus_start_last_mode")
    }
  }

  var systemImage: String {
    switch self {
      case .marker: "pencil.and.outline"
      case .objectPlacement: "cube.fill"
      case .lengthMeasurement: "ruler"
      case .areaMeasurement: "triangle"
      case .volumeMeasurement: "cube"
      case .lastMode: "clock.arrow.circlepath"
    }
  }
}

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
  case measurementMode
  case screenViewMode
  case nextControllerTool
  case controllerModelTool
  case controllerClippingTool
  case controllerMarkerTool
  case controllerObjectTool
  case nextActiveObject
  case controllerMeasurementTool
  case controllerAreaMeasurementTool
  case controllerVolumeMeasurementTool
  case nextRenderMode
  case transferFunctionLightingMode
  case transferFunctionMode
  case isoValueMode
  case toggleCurrentEditor
  case toggleMarkerWindow
  case toggleMeasurementWindow
  case toggleLightingWindow
  case toggleInteractionWindow
  case resetModel
  case resetClipping
  case deleteLastMarker
  case deleteSelectedMarkers
  case toggleSelectedMarkerDirections
  case deleteSelectedMeasurementPoint

  var id: String { rawValue }

  var category: Category {
    switch self {
      case .none:
        .general
      case .nextInteractionMode, .modelMode, .clippingMode, .markerMode, .measurementMode,
           .screenViewMode, .nextControllerTool, .controllerModelTool,
           .controllerClippingTool, .controllerMarkerTool, .controllerObjectTool,
           .nextActiveObject, .controllerMeasurementTool,
           .controllerAreaMeasurementTool, .controllerVolumeMeasurementTool:
        .interaction
      case .nextRenderMode, .transferFunctionLightingMode, .transferFunctionMode, .isoValueMode:
        .rendering
      case .toggleCurrentEditor, .toggleMarkerWindow, .toggleMeasurementWindow,
           .toggleLightingWindow,
           .toggleInteractionWindow:
        .windows
      case .resetModel, .resetClipping, .deleteLastMarker, .deleteSelectedMarkers,
           .toggleSelectedMarkerDirections, .deleteSelectedMeasurementPoint:
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
      case .measurementMode: String(localized: "controller_action_measurement_mode")
      case .screenViewMode: String(localized: "controller_action_screen_view_mode")
      case .nextControllerTool: String(localized: "controller_action_next_controller_tool")
      case .controllerModelTool: String(localized: "controller_action_controller_model_tool")
      case .controllerClippingTool:
        String(localized: "controller_action_controller_clipping_tool")
      case .controllerMarkerTool: String(localized: "controller_action_controller_marker_tool")
      case .controllerObjectTool: String(localized: "Place Objects")
      case .nextActiveObject: String(localized: "Next Active Object")
      case .controllerMeasurementTool:
        String(localized: "controller_action_controller_measurement_tool")
      case .controllerAreaMeasurementTool:
        String(localized: "controller_action_controller_area_measurement_tool")
      case .controllerVolumeMeasurementTool:
        String(localized: "controller_action_controller_volume_measurement_tool")
      case .nextRenderMode: String(localized: "controller_action_next_render_mode")
      case .transferFunctionLightingMode:
        String(localized: "controller_action_tf_lighting_mode")
      case .transferFunctionMode: String(localized: "controller_action_tf_mode")
      case .isoValueMode: String(localized: "controller_action_iso_mode")
      case .toggleCurrentEditor: String(localized: "controller_action_toggle_current_editor")
      case .toggleMarkerWindow: String(localized: "controller_action_toggle_marker_window")
      case .toggleMeasurementWindow:
        String(localized: "controller_action_toggle_measurement_window")
      case .toggleLightingWindow: String(localized: "controller_action_toggle_lighting_window")
      case .toggleInteractionWindow:
        String(localized: "controller_action_toggle_interaction_window")
      case .resetModel: String(localized: "controller_action_reset_model")
      case .resetClipping: String(localized: "controller_action_reset_clipping")
      case .deleteLastMarker:
        String(localized: "controller_action_delete_last_marker")
      case .deleteSelectedMarkers:
        String(localized: "controller_action_delete_selected_markers")
      case .toggleSelectedMarkerDirections:
        String(localized: "controller_action_toggle_marker_directions")
      case .deleteSelectedMeasurementPoint:
        String(localized: "controller_action_delete_measurement_point")
    }
  }

  var systemImage: String {
    switch self {
      case .none: "slash.circle"
      case .nextInteractionMode: "hand.tap"
      case .modelMode: "move.3d"
      case .clippingMode: "crop"
      case .markerMode: "mappin"
      case .measurementMode: "ruler"
      case .screenViewMode: "rectangle.on.rectangle"
      case .nextControllerTool: "arrow.trianglehead.2.clockwise.rotate.90"
      case .controllerModelTool: "move.3d"
      case .controllerClippingTool: "crop"
      case .controllerMarkerTool: "pencil.and.outline"
      case .controllerObjectTool: "cube.fill"
      case .nextActiveObject: "arrow.trianglehead.2.clockwise.rotate.90"
      case .controllerMeasurementTool: "ruler"
      case .controllerAreaMeasurementTool: "triangle"
      case .controllerVolumeMeasurementTool: "cube"
      case .nextRenderMode: "rectangle.3.group"
      case .transferFunctionLightingMode: "lightbulb"
      case .transferFunctionMode: "chart.xyaxis.line"
      case .isoValueMode: "square.3.layers.3d.top.filled"
      case .toggleCurrentEditor: "slider.horizontal.3"
      case .toggleMarkerWindow: "cube.transparent"
      case .toggleMeasurementWindow: "ruler"
      case .toggleLightingWindow: "lightbulb.max"
      case .toggleInteractionWindow: "hand.draw"
      case .resetModel: "arrow.counterclockwise"
      case .resetClipping: "crop.rotate"
      case .deleteLastMarker: "delete.backward"
      case .deleteSelectedMarkers: "trash"
      case .toggleSelectedMarkerDirections: "location.north.line"
      case .deleteSelectedMeasurementPoint: "point.bottomleft.forward.to.point.topright.scurvepath"
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
    for chirality: BorgSpatialInputChirality,
    runtimeAppModel: RuntimeAppModel,
    sharedAppModel: SharedAppModel,
    storedAppModel: StoredAppModel
  ) {
    switch action {
      case .none:
        break
      case .nextInteractionMode:
        advanceControllerTool(
          for: chirality,
          sharedAppModel: sharedAppModel,
          storedAppModel: storedAppModel
        )
      case .modelMode:
        storedAppModel.setControllerTool(.model, for: chirality)
      case .clippingMode:
        storedAppModel.setControllerTool(.clipping, for: chirality)
      case .markerMode:
        storedAppModel.setControllerTool(.marker, for: chirality)
      case .measurementMode:
        storedAppModel.setControllerTool(.lengthMeasurement, for: chirality)
      case .screenViewMode:
        guard hasSharedScreenView(sharedAppModel) else { return }
        storedAppModel.setControllerTool(.screenView, for: chirality)
      case .nextControllerTool:
        advanceControllerTool(
          for: chirality,
          sharedAppModel: sharedAppModel,
          storedAppModel: storedAppModel
        )
      case .controllerModelTool:
        storedAppModel.setControllerTool(.model, for: chirality)
      case .controllerClippingTool:
        storedAppModel.setControllerTool(.clipping, for: chirality)
      case .controllerMarkerTool:
        storedAppModel.setControllerTool(.marker, for: chirality)
      case .controllerObjectTool:
        storedAppModel.setControllerTool(.objectPlacement, for: chirality)
      case .nextActiveObject:
        sharedAppModel.selectNextSceneObjectPrototype()
      case .controllerMeasurementTool:
        storedAppModel.setControllerTool(.lengthMeasurement, for: chirality)
      case .controllerAreaMeasurementTool:
        storedAppModel.setControllerTool(.areaMeasurement, for: chirality)
      case .controllerVolumeMeasurementTool:
        storedAppModel.setControllerTool(.volumeMeasurement, for: chirality)
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
      case .toggleMeasurementWindow:
        runtimeAppModel.requestAuxiliaryWindowToggle("MeasurementView")
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
      case .deleteLastMarker:
        if sharedAppModel.removeLastVolumeMarker() {
          sharedAppModel.synchronizeMarkers()
        }
      case .deleteSelectedMarkers:
        let selectedIDs = sharedAppModel.selectedVolumeMarkerIDs
        if sharedAppModel.removeVolumeMarkers(withIDs: selectedIDs) {
          sharedAppModel.synchronizeMarkers()
        }
      case .toggleSelectedMarkerDirections:
        let markerIDs = Set(sharedAppModel.volumeMarkers.compactMap { marker in
          sharedAppModel.selectedVolumeMarkerIDs.contains(marker.id) && marker.kind == .sphere
            ? marker.id
            : nil
        })
        guard !markerIDs.isEmpty else { return }
        let showDirections = !sharedAppModel.volumeMarkers
          .filter { markerIDs.contains($0.id) }
          .allSatisfy(\.showsDirection)
        for markerID in markerIDs {
          guard let index = sharedAppModel.volumeMarkers.firstIndex(where: {
            $0.id == markerID
          }) else { continue }
          sharedAppModel.volumeMarkers[index].showsDirection = showDirections
        }
        sharedAppModel.defaultVolumeMarkerShowsDirection = showDirections
        sharedAppModel.synchronizeMarkers()
      case .deleteSelectedMeasurementPoint:
        _ = sharedAppModel.removeSelectedVolumeMeasurementPoint()
    }
  }

  private static func hasSharedScreenView(_ sharedAppModel: SharedAppModel) -> Bool {
    sharedAppModel.screenSharePlayViewState != nil &&
      sharedAppModel.sharePlayParticipants.contains {
        $0.platform == .iOS || $0.platform == .macOS
      }
  }

  private static func advanceControllerTool(
    for chirality: BorgSpatialInputChirality,
    sharedAppModel: SharedAppModel,
    storedAppModel: StoredAppModel
  ) {
    var tools = SpatialToolMode.allCases
    if !hasSharedScreenView(sharedAppModel) {
      tools.removeAll { $0 == .screenView }
    }
    let current = storedAppModel.controllerTool(for: chirality)
    let currentIndex = tools.firstIndex(of: current) ?? -1
    storedAppModel.setControllerTool(tools[(currentIndex + 1) % tools.count], for: chirality)
  }

  private static func setRenderMode(_ mode: RenderMode, sharedAppModel: SharedAppModel) {
    sharedAppModel.renderMode = mode
    sharedAppModel.synchronize(kind: .stateOnly)
  }
}
