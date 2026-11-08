import Foundation

/// Local UI preferences, deliberately independent of SharePlay and automation state.
struct InterfaceVisibility: Equatable {
  enum Interaction: String, CaseIterable, Identifiable {
    case model, clipping, transferEditing, drawing, objectPlacement, measurement, volumeEditing
    var id: String { rawValue }
    var bit: Int { 1 << Self.allCases.firstIndex(of: self)! }
    var title: String {
      switch self {
        case .model: "Model"
        case .clipping: "Clipping"
        case .transferEditing: "Transfer"
        case .drawing: "Draw"
        case .objectPlacement: "Place"
        case .measurement: "measurement_window_title"
        case .volumeEditing: "Edit Volume"
      }
    }
    var icon: String {
      switch self {
        case .model: "move.3d"
        case .clipping: "viewfinder"
        case .transferEditing: "slider.horizontal.3"
        case .drawing: "scribble"
        case .objectPlacement: "cube"
        case .measurement: "ruler"
        case .volumeEditing: "eraser"
      }
    }
  }

  enum Panel: Int, CaseIterable, Identifiable {
    case lighting, transfer, objects, measurements, brush
    var id: Int { rawValue }
    var bit: Int { 1 << rawValue }
    var title: String {
      switch self {
        case .lighting: "Lighting"
        case .transfer: "Transfer / Isovalue Editor"
        case .objects: "Objects"
        case .measurements: "measurement_window_title"
        case .brush: "Brush"
      }
    }
  }

  static let allRenderModes = 7
  static let allInteractions = 127
  static let allPanels = 31
  var renderModes = allRenderModes
  var interactions = allInteractions
  var panels = allPanels
  var showsResets = true
  var showsPanels = true

  var renderModeIDs: [UInt8] {
    let mask = renderModes & Self.allRenderModes
    return (0..<3).filter { (mask == 0 ? 1 : mask) & (1 << $0) != 0 }.map(UInt8.init)
  }
  /// A shared active mode is visible for context, without becoming a local choice.
  func displayedRenderModeIDs(active: UInt8, inSharePlay: Bool) -> [UInt8] {
    let allowed = renderModeIDs
    guard inSharePlay, active < 3, !allowed.contains(active) else { return allowed }
    return (allowed + [active]).sorted()
  }
  var interactionModes: [Interaction] {
    let mask = interactions & Self.allInteractions
    return Interaction.allCases.filter { (mask == 0 ? 1 : mask) & $0.bit != 0 }
  }
  func allowsInteraction(_ rawValue: String) -> Bool {
    interactionModes.contains { $0.rawValue == rawValue }
  }
  func showsPanel(_ panel: Panel) -> Bool { showsPanels && panels & panel.bit != 0 }
  /// Screen clients have no independent stylus/controller modes that need these panels.
  func showsScreenPanel(_ panel: Panel) -> Bool {
    guard showsPanel(panel) else { return false }
    switch panel {
      case .lighting: return true
      case .transfer: return interactionModes.contains(.transferEditing)
      case .objects: return interactionModes.contains(.drawing) || interactionModes.contains(.objectPlacement)
      case .measurements: return interactionModes.contains(.measurement)
      case .brush: return interactionModes.contains(.volumeEditing)
    }
  }
  var hasPanels: Bool { showsPanels && panels & Self.allPanels != 0 }
  var hasScreenPanels: Bool { Panel.allCases.contains(where: showsScreenPanel) }
  var isCustomized: Bool { self != Self() }

  mutating func setRenderMode(_ id: UInt8, enabled: Bool) {
    guard id < 3 else { return }
    let bit = 1 << Int(id)
    let mask = renderModeIDs.reduce(0) { $0 | (1 << Int($1)) }
    let updated = enabled ? mask | bit : mask & ~bit
    if updated != 0 { renderModes = updated }
  }
  mutating func setInteraction(_ mode: Interaction, enabled: Bool) {
    let mask = interactionModes.reduce(0) { $0 | $1.bit }
    let updated = enabled ? mask | mode.bit : mask & ~mode.bit
    if updated != 0 { interactions = updated }
  }
  mutating func setPanel(_ panel: Panel, enabled: Bool) {
    panels = enabled ? panels | panel.bit : panels & ~panel.bit
  }
}

protocol InterfaceVisibilitySettings: AnyObject {
  var uiRenderModes: Int { get set }
  var uiInteractionModes: Int { get set }
  var uiPanelButtons: Int { get set }
  var showModeResetButtons: Bool { get set }
  var showPanelButtons: Bool { get set }
}

extension InterfaceVisibilitySettings {
  var interfaceVisibility: InterfaceVisibility {
    get {
      InterfaceVisibility(renderModes: uiRenderModes, interactions: uiInteractionModes,
        panels: uiPanelButtons, showsResets: showModeResetButtons, showsPanels: showPanelButtons)
    }
    set {
      uiRenderModes = newValue.renderModes
      uiInteractionModes = newValue.interactions
      uiPanelButtons = newValue.panels
      showModeResetButtons = newValue.showsResets
      showPanelButtons = newValue.showsPanels
    }
  }
}
