import SwiftUI

struct PanelAction: Identifiable, Equatable {
  let id: String
  let icon: String?
  let text: String
  var shortcutHint: String?
  var isEnabled = true
  var isSelected = false
  var tint: Color?
  var children: [PanelAction]?
  let perform: () -> Void

  static func button(_ id: String, icon: String, text: String, enabled: Bool = true,
                     selected: Bool = false, tint: Color? = nil, shortcutHint: String? = nil,
                     action: @escaping () -> Void) -> Self {
    Self(id: id, icon: icon, text: text, shortcutHint: shortcutHint,
      isEnabled: enabled, isSelected: selected, tint: tint, perform: action)
  }

  var helpText: String { shortcutHint.map { "\(text) (\($0))" } ?? text }

  static func menu(_ id: String, icon: String, text: String, items: [PanelAction]) -> Self {
    Self(id: id, icon: icon, text: text, children: items, perform: {})
  }

  static func spacer(_ id: String) -> Self {
    Self(id: id, icon: nil, text: "", perform: {})
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.icon == rhs.icon && lhs.text == rhs.text &&
      lhs.shortcutHint == rhs.shortcutHint &&
      lhs.isEnabled == rhs.isEnabled && lhs.isSelected == rhs.isSelected &&
      lhs.tint == rhs.tint && lhs.children == rhs.children
  }

  static func groups(_ items: [Self]) -> [[Self]] {
    var result: [[Self]] = []
    var group: [Self] = []
    for item in items {
      if item.icon == nil {
        if !group.isEmpty { result.append(group); group = [] }
      } else {
        group.append(item)
      }
    }
    if !group.isEmpty { result.append(group) }
    return result
  }
}

struct PanelTitleFormat: Equatable {
  var color: Color?
  var isItalic = false
  var isBold = true
}

struct PanelTitleProgress: Equatable {
  var fraction: Double
  var color: Color = .red
  var statusText: String
}

struct PanelWindowConfiguration: Equatable {
  var title: String?
  var titleFormat = PanelTitleFormat()
  var titleProgress: PanelTitleProgress?
  var leading: [PanelAction] = []
  var actions: [PanelAction] = []

  static func standard(title: String? = nil, titleFormat: PanelTitleFormat = .init(),
                       titleProgress: PanelTitleProgress? = nil, reset: PanelAction, load: PanelAction,
                       save: PanelAction, additional: [PanelAction] = [], leading: [PanelAction] = []) -> Self {
    Self(title: title, titleFormat: titleFormat, titleProgress: titleProgress, leading: leading,
      actions: [reset, .spacer("files"), load, save] + (additional.isEmpty ? [] : [.spacer("additional")] + additional))
  }
}

@MainActor
final class PanelWindow: ObservableObject {
  let panel: DockablePanelID
  @Published private(set) var configuration = PanelWindowConfiguration()
  private var owner: UUID?

  init(panel: DockablePanelID) { self.panel = panel }

  var title: String { configuration.title ?? panel.displayTitle }
  var titleColor: Color { configuration.titleFormat.color ?? panel.tint }

  func register(_ configuration: PanelWindowConfiguration, owner: UUID) {
    self.owner = owner
    self.configuration = configuration
  }

  func unregister(owner: UUID) {
    guard self.owner == owner else { return }
    self.owner = nil
    configuration = PanelWindowConfiguration()
  }
}

private struct PanelWindowEnvironmentKey: EnvironmentKey {
  static let defaultValue: PanelWindow? = nil
}

extension EnvironmentValues {
  var panelWindow: PanelWindow? {
    get { self[PanelWindowEnvironmentKey.self] }
    set { self[PanelWindowEnvironmentKey.self] = newValue }
  }
}

private struct RegisterPanelActions: ViewModifier {
  @Environment(\.panelWindow) private var window
  @State private var owner = UUID()
  let configuration: PanelWindowConfiguration

  func body(content: Content) -> some View {
    content
      .onAppear { window?.register(configuration, owner: owner) }
      .onChange(of: configuration) { _, value in
        window?.register(value, owner: owner)
      }
      .onDisappear { window?.unregister(owner: owner) }
  }
}

extension View {
  func panelActions(_ configuration: PanelWindowConfiguration) -> some View {
    modifier(RegisterPanelActions(configuration: configuration))
  }
}

struct PanelActionButtons: View {
  let items: [PanelAction]

  var body: some View {
    HStack(spacing: 8) {
      ForEach(Array(PanelAction.groups(items).enumerated()), id: \.offset) { _, group in
        HStack(spacing: 1) {
          ForEach(group) { item in
            PanelActionButton(item: item)
          }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
      }
    }
    .font(.system(size: 12, weight: .medium))
  }
}

struct PanelActionButton: View {
  let item: PanelAction

  var body: some View {
    Group {
      if let children = item.children {
        Menu {
          ForEach(children) { child in
            if child.icon == nil { Divider() }
            else {
              Button(action: child.perform) {
                Label(child.text, systemImage: child.icon ?? "circle")
              }
              .disabled(!child.isEnabled)
            }
          }
        } label: {
          Label(item.text, systemImage: item.icon ?? "ellipsis")
            .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!item.isEnabled || children.isEmpty)
        .padding(.horizontal, 4)
      } else {
        Button(action: item.perform) {
          Label(item.text, systemImage: item.icon ?? "circle")
            .labelStyle(.iconOnly)
            .frame(width: 26, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(item.isSelected ? Color.accentColor.opacity(0.18) : .clear,
          in: RoundedRectangle(cornerRadius: 4))
        .disabled(!item.isEnabled)
      }
    }
    .foregroundStyle(item.tint ?? .primary)
    .help(item.helpText)
    .accessibilityLabel(item.text)
  }
}
