import AppKit
import SwiftUI

enum DockablePanelID: String, CaseIterable, Identifiable {
  case renderControls
  case transferFunctionEditor
  case isoEditor
  case markerEditor
  case measurementEditor
  case lightingEditor
  case volumeBrushEditor

  var id: String { rawValue }
  var windowID: String { "dockable.\(rawValue)" }
  var windowFrameAutosaveName: String { "BorgVR.\(windowID).utility.frame" }

  var title: LocalizedStringKey {
    switch self {
      case .renderControls:
        return "Render UI"
      case .transferFunctionEditor:
        return "Transfer Function"
      case .isoEditor:
        return "Isovalue"
      case .markerEditor:
        return "Objects"
      case .measurementEditor:
        return "measurement_window_title"
      case .lightingEditor:
        return "Lighting"
      case .volumeBrushEditor:
        return "Brush"
    }
  }

  var displayTitle: String {
    switch self {
      case .renderControls: String(localized: "Render UI")
      case .transferFunctionEditor: String(localized: "Transfer Function")
      case .isoEditor: String(localized: "Isovalue")
      case .markerEditor: String(localized: "Objects")
      case .measurementEditor: String(localized: "measurement_window_title")
      case .lightingEditor: String(localized: "Lighting")
      case .volumeBrushEditor: String(localized: "Brush")
    }
  }

  var dockedIcon: String {
    "rectangle.on.rectangle"
  }

  var detachedIcon: String {
    "rectangle.compress.vertical"
  }

  var tint: Color {
    switch self {
      case .renderControls, .lightingEditor: .primary
      case .transferFunctionEditor, .isoEditor: .purple
      case .markerEditor: .orange
      case .measurementEditor: .green
      case .volumeBrushEditor: .red
    }
  }

  var inlineWidth: CGFloat {
    switch self {
      case .renderControls: 1100
      case .transferFunctionEditor: 720
      case .isoEditor: 520
      case .markerEditor, .measurementEditor: 380
      case .lightingEditor, .volumeBrushEditor: 340
    }
  }

  func inlineHeight(in container: CGSize) -> CGFloat? {
    switch self {
      case .markerEditor, .measurementEditor: min(560, max(240, container.height - 280))
      default: nil
    }
  }

  func initialOrigin(in container: CGSize, panelSize: CGSize) -> CGPoint {
    let bottom = container.height - panelSize.height - 16
    switch self {
      case .renderControls:
        return CGPoint(x: (container.width - panelSize.width) / 2, y: 16)
      case .transferFunctionEditor, .isoEditor:
        return CGPoint(x: (container.width - panelSize.width) / 2, y: bottom)
      case .lightingEditor:
        return CGPoint(x: 16, y: bottom)
      case .volumeBrushEditor:
        return CGPoint(x: 372, y: bottom)
      case .markerEditor:
        return CGPoint(x: container.width - panelSize.width * 2 - 32, y: bottom)
      case .measurementEditor:
        return CGPoint(x: container.width - panelSize.width - 16, y: bottom)
    }
  }
}

enum PanelDockAnchor: String, CaseIterable {
  case topLeading, top, topTrailing
  case leading, trailing
  case bottomLeading, bottom, bottomTrailing

  func origin(panelSize: CGSize, containerSize: CGSize) -> CGPoint {
    let horizontal: CGFloat
    let vertical: CGFloat
    switch self {
      case .topLeading: (horizontal, vertical) = (0, 0)
      case .top: (horizontal, vertical) = (0.5, 0)
      case .topTrailing: (horizontal, vertical) = (1, 0)
      case .leading: (horizontal, vertical) = (0, 0.5)
      case .trailing: (horizontal, vertical) = (1, 0.5)
      case .bottomLeading: (horizontal, vertical) = (0, 1)
      case .bottom: (horizontal, vertical) = (0.5, 1)
      case .bottomTrailing: (horizontal, vertical) = (1, 1)
    }
    return CGPoint(x: 8 + max(0, containerSize.width - panelSize.width - 16) * horizontal,
      y: 8 + max(0, containerSize.height - panelSize.height - 16) * vertical)
  }
}

@MainActor
final class DockingController: ObservableObject {
  struct RevealControl: Identifiable {
    let id: DockablePanelID
    let icon: String
    let text: String
  }
  private static let visiblePanelsKey = "dockable.visiblePanels"
  private static let detachedPanelsKey = "dockable.detachedPanels"
  private static let panelOriginsKey = "dockable.panelOrigins"
  private static let panelAnchorsKey = "dockable.panelAnchors"
  private let defaults: UserDefaults

  @Published private var visiblePanels: Set<DockablePanelID>
  @Published private var detachedPanels: Set<DockablePanelID>
  @Published private var panelOrigins: [DockablePanelID: CGPoint] = [:]
  @Published private var panelAnchors: [DockablePanelID: PanelDockAnchor] = [:]
  @Published private var panelOrder = DockablePanelID.allCases
  @Published private(set) var revealControls: [RevealControl] = []
  @Published var showsLog = false
  @Published var showsDatasetInfo = false
  @Published private(set) var commandRequest: MacCommandRequest? = nil
  private var datasetLifecycleClosingPanels: Set<DockablePanelID> = []
  private var transientClosingPanels: Set<DockablePanelID> = []

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    visiblePanels = Self.loadPanels(
      defaults: defaults,
      forKey: Self.visiblePanelsKey,
      defaultValue: [.renderControls]
    )
    detachedPanels = Self.loadPanels(
      defaults: defaults,
      forKey: Self.detachedPanelsKey,
      defaultValue: []
    )
    visiblePanels.formUnion(detachedPanels)
    if let origins = defaults.dictionary(forKey: Self.panelOriginsKey) as? [String: [Double]] {
      for (key, values) in origins where values.count == 2 && values.allSatisfy(\.isFinite) {
        if let panel = DockablePanelID(rawValue: key) {
          panelOrigins[panel] = CGPoint(x: values[0], y: values[1])
        }
      }
    }
    if let anchors = defaults.dictionary(forKey: Self.panelAnchorsKey) as? [String: String] {
      for (key, value) in anchors {
        if let panel = DockablePanelID(rawValue: key), let anchor = PanelDockAnchor(rawValue: value) {
          panelAnchors[panel] = anchor
        }
      }
    }
  }

  func isVisible(_ panel: DockablePanelID) -> Bool {
    visiblePanels.contains(panel)
  }

  func isDetached(_ panel: DockablePanelID) -> Bool {
    detachedPanels.contains(panel)
  }

  func isDockedVisible(_ panel: DockablePanelID) -> Bool {
    isVisible(panel) && !isDetached(panel)
  }

  func show(_ panel: DockablePanelID) {
    visiblePanels.insert(panel)
    bringToFront(panel)
    persistLayout()
  }

  func hide(_ panel: DockablePanelID) {
    visiblePanels.remove(panel)
    persistLayout()
  }

  func toggleVisibility(_ panel: DockablePanelID) {
    if isVisible(panel) {
      hide(panel)
    } else {
      show(panel)
    }
  }

  func request(_ command: MacCommand) {
    commandRequest = MacCommandRequest(command: command)
  }

  func registerRevealControl(for panel: DockablePanelID, icon: String, text: String) {
    revealControls.removeAll { $0.id == panel }
    revealControls.append(RevealControl(id: panel, icon: icon, text: text))
  }

  func detach(_ panel: DockablePanelID) {
    visiblePanels.insert(panel)
    detachedPanels.insert(panel)
    persistLayout()
  }

  func dock(_ panel: DockablePanelID) {
    detachedPanels.remove(panel)
    visiblePanels.insert(panel)
    bringToFront(panel)
    persistLayout()
  }

  func close(_ panel: DockablePanelID) {
    if isDetached(panel) { transientClosingPanels.insert(panel) }
    hide(panel)
    detachedPanels.remove(panel)
    persistLayout()
  }

  func resetForDatasetClose() {
    showsLog = false
    showsDatasetInfo = false
    datasetLifecycleClosingPanels.formUnion(detachedPanels)
    detachedPanels.removeAll()
    visiblePanels.removeAll()
  }

  func restoreForDatasetOpen() {
    visiblePanels = Self.loadPanels(
      defaults: defaults,
      forKey: Self.visiblePanelsKey,
      defaultValue: [.renderControls]
    )
    detachedPanels = Self.loadPanels(
      defaults: defaults,
      forKey: Self.detachedPanelsKey,
      defaultValue: []
    )
    visiblePanels.formUnion(detachedPanels)
  }

  func detachedWindowDidDisappear(_ panel: DockablePanelID) {
    if datasetLifecycleClosingPanels.remove(panel) != nil {
      return
    }
    if transientClosingPanels.remove(panel) != nil {
      return
    }
    guard isDetached(panel) else { return }
    visiblePanels.remove(panel)
    detachedPanels.remove(panel)
    persistLayout()
  }

  func bringToFront(_ panel: DockablePanelID) {
    guard panelOrder.last != panel else { return }
    panelOrder.removeAll { $0 == panel }
    panelOrder.append(panel)
  }

  func zIndex(for panel: DockablePanelID) -> Double {
    Double(panelOrder.firstIndex(of: panel) ?? 0)
  }

  func origin(for panel: DockablePanelID, panelSize: CGSize, containerSize: CGSize) -> CGPoint {
    if let anchor = panelAnchors[panel] {
      return anchor.origin(panelSize: panelSize, containerSize: containerSize)
    }
    return Self.clampedOrigin(panelOrigins[panel] ?? panel.initialOrigin(in: containerSize, panelSize: panelSize),
      panelSize: panelSize, containerSize: containerSize)
  }

  func move(_ panel: DockablePanelID, to origin: CGPoint, panelSize: CGSize, containerSize: CGSize) {
    guard origin.x.isFinite, origin.y.isFinite else { return }
    panelAnchors[panel] = nil
    panelOrigins[panel] = Self.clampedOrigin(origin, panelSize: panelSize, containerSize: containerSize)
  }

  func dockAnchor(for panel: DockablePanelID) -> PanelDockAnchor? { panelAnchors[panel] }

  func snapCandidate(for panel: DockablePanelID, panelSize: CGSize, containerSize: CGSize) -> PanelDockAnchor? {
    guard panelSize.width > 0, panelSize.height > 0 else { return nil }
    let current = origin(for: panel, panelSize: panelSize, containerSize: containerSize)
    var nearest: PanelDockAnchor?
    var distanceSquared: CGFloat = 28 * 28
    for anchor in PanelDockAnchor.allCases {
      let target = anchor.origin(panelSize: panelSize, containerSize: containerSize)
      let dx = current.x - target.x
      let dy = current.y - target.y
      let distance = dx * dx + dy * dy
      if distance < distanceSquared {
        nearest = anchor
        distanceSquared = distance
      }
    }
    return nearest
  }

  func finishMoving(_ panel: DockablePanelID, panelSize: CGSize, containerSize: CGSize) {
    if let anchor = snapCandidate(for: panel, panelSize: panelSize, containerSize: containerSize) {
      panelAnchors[panel] = anchor
    }
    savePanelPositions()
  }

  func savePanelPositions() {
    defaults.set(Dictionary(uniqueKeysWithValues: panelOrigins.map {
      ($0.key.rawValue, [Double($0.value.x), Double($0.value.y)])
    }), forKey: Self.panelOriginsKey)
    defaults.set(Dictionary(uniqueKeysWithValues: panelAnchors.map {
      ($0.key.rawValue, $0.value.rawValue)
    }), forKey: Self.panelAnchorsKey)
  }

  private static func clampedOrigin(_ origin: CGPoint, panelSize: CGSize, containerSize: CGSize) -> CGPoint {
    CGPoint(x: min(max(8, origin.x), max(8, containerSize.width - panelSize.width - 8)),
      y: min(max(8, origin.y), max(8, containerSize.height - panelSize.height - 8)))
  }

  func detachedPanelsToRestore(compatibleWith renderMode: RenderMode) -> [DockablePanelID] {
    DockablePanelID.allCases.filter { panel in
      isVisible(panel) && isDetached(panel) && isCompatible(panel, with: renderMode)
    }
  }

  func detachedPanelsToTemporarilyClose(incompatibleWith renderMode: RenderMode) -> [DockablePanelID] {
    DockablePanelID.allCases.filter { panel in
      isVisible(panel) && isDetached(panel) && !isCompatible(panel, with: renderMode)
    }
  }

  func markDetachedWindowTemporarilyClosed(_ panel: DockablePanelID) {
    transientClosingPanels.insert(panel)
  }

  func showEditor(for renderMode: RenderMode) {
    if renderMode == .isoValue {
      show(.isoEditor)
    } else {
      show(.transferFunctionEditor)
    }
  }

  func toggleEditor(for renderMode: RenderMode) {
    if renderMode == .isoValue {
      toggleVisibility(.isoEditor)
    } else {
      toggleVisibility(.transferFunctionEditor)
    }
  }

  func hideIncompatibleEditor(for _: RenderMode) {
    // Incompatible editors are only hidden by the current render mode. The user's
    // saved docking layout must survive switching between TF and ISO rendering.
  }

  private func isCompatible(_ panel: DockablePanelID, with renderMode: RenderMode) -> Bool {
    switch panel {
      case .renderControls, .markerEditor, .measurementEditor, .lightingEditor, .volumeBrushEditor:
        return true
      case .transferFunctionEditor:
        return renderMode != .isoValue
      case .isoEditor:
        return renderMode == .isoValue
    }
  }

  private func persistLayout() {
    defaults.set(
      visiblePanels.map(\.rawValue).sorted(),
      forKey: Self.visiblePanelsKey
    )
    defaults.set(
      detachedPanels.map(\.rawValue).sorted(),
      forKey: Self.detachedPanelsKey
    )
  }

  private static func loadPanels(
    defaults: UserDefaults,
    forKey key: String,
    defaultValue: Set<DockablePanelID>
  ) -> Set<DockablePanelID> {
    guard let rawValues = defaults.stringArray(forKey: key) else {
      return defaultValue
    }
    return Set(rawValues.compactMap(DockablePanelID.init(rawValue:)))
  }
}
