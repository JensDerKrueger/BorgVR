import AppKit
import SwiftUI

struct NativePanelToolbar: NSViewRepresentable {
  @ObservedObject var model: PanelWindow
  let dock: () -> Void

  final class AttachmentView: NSView {
    var windowChanged: ((NSWindow?) -> Void)?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      windowChanged?(window)
    }
  }

  @MainActor final class Coordinator: NSObject, NSToolbarDelegate {
    let toolbar: NSToolbar
    private weak var window: NSWindow?
    private var actions: [NSToolbarItem.Identifier: PanelAction] = [:]
    private var identifiers: [NSToolbarItem.Identifier] = []
    private var title = ""
    private let titleIdentifier = NSToolbarItem.Identifier("window.title")
    private var titleColor = NSColor.labelColor
    private var titleFormat = PanelTitleFormat()
    private var titleFont: NSFont {
      let font = NSFont.systemFont(ofSize: 12, weight: titleFormat.isBold ? .semibold : .regular)
      return titleFormat.isItalic ? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) : font
    }
    private var updateScheduled = false

    init(panel: DockablePanelID) {
      toolbar = NSToolbar(identifier: "BorgVR.\(panel.rawValue).actions")
      super.init()
      toolbar.delegate = self
      toolbar.displayMode = .iconOnly
      toolbar.sizeMode = .small
      toolbar.allowsUserCustomization = false
      toolbar.allowsDisplayModeCustomization = false
    }

    func attach(to window: NSWindow?) {
      guard self.window !== window else { return }
      self.window = window
      scheduleUpdate()
    }

    func update(_ model: PanelWindow, dock: @escaping () -> Void) {
      title = model.title
      titleFormat = model.configuration.titleFormat
      titleColor = NSColor(model.titleColor)
      actions.removeAll(keepingCapacity: true)
      identifiers.removeAll(keepingCapacity: true)
      func append(_ items: [PanelAction], prefix: String) {
        for item in items {
          let identifier = NSToolbarItem.Identifier("\(prefix).\(item.id)")
          actions[identifier] = item
          identifiers.append(identifier)
        }
      }
      append(model.configuration.leading, prefix: "leading")
      identifiers.append(titleIdentifier)
      identifiers.append(.flexibleSpace)
      append(model.configuration.actions, prefix: "action")
      append([.button("dock", icon: model.panel.detachedIcon,
        text: String(localized: "Dock panel"),
        shortcutHint: model.panel == .renderControls ? MacRenderShortcut.docking.displayName : nil,
        action: dock)], prefix: "window")
      scheduleUpdate()
    }

    private func scheduleUpdate() {
      guard !updateScheduled else { return }
      updateScheduled = true
      // Installing/removing a toolbar inside viewDidMoveToWindow can reenter
      // AppKit's view teardown. Apply only after that hierarchy update finishes.
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.updateScheduled = false
        guard let window = self.window else { return }
        window.title = self.title
        window.titleVisibility = .hidden
        if window.toolbar !== self.toolbar { window.toolbar = self.toolbar }
        self.toolbar.itemIdentifiers = self.identifiers
        for item in self.toolbar.items { self.configure(item) }
      }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
      let item = NSToolbarItem(itemIdentifier: identifier)
      if identifier == titleIdentifier {
        let label = NSTextField(labelWithString: title)
        label.font = titleFont
        label.textColor = titleColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        item.view = label
        item.visibilityPriority = .low
        item.menuFormRepresentation = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        return item
      }
      guard let action = actions[identifier] else { return nil }
      let view: NSView
      if action.icon == nil {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 24))
      } else {
        let button = NSButton(title: "", target: self, action: #selector(performAction(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(identifier.rawValue)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.setButtonType(.momentaryChange)
        view = button
      }
      view.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        view.widthAnchor.constraint(equalToConstant: action.icon == nil ? 8 : 26),
        view.heightAnchor.constraint(equalToConstant: 24)
      ])
      item.view = view
      item.target = self
      item.action = #selector(performAction(_:))
      item.autovalidates = false
      item.visibilityPriority = action.icon == nil ? .low : .high
      configure(item)
      return item
    }

    private func configure(_ item: NSToolbarItem) {
      if item.itemIdentifier == titleIdentifier {
        (item.view as? NSTextField)?.stringValue = title
        (item.view as? NSTextField)?.textColor = titleColor
        (item.view as? NSTextField)?.font = titleFont
        item.toolTip = title
        return
      }
      guard let action = actions[item.itemIdentifier] else { return }
      item.label = action.text
      item.paletteLabel = action.text
      item.toolTip = action.helpText
      item.isEnabled = action.isEnabled
      item.menuFormRepresentation = menuItem(for: action)
      if let button = item.view as? NSButton {
        button.image = action.icon.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: action.text) }?
          .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        button.image?.isTemplate = true
        button.contentTintColor = action.tint.map(NSColor.init) ?? (action.isSelected ? .controlAccentColor : nil)
        button.toolTip = action.helpText
        button.setAccessibilityLabel(action.text)
      }
    }

    private func menuItem(for action: PanelAction) -> NSMenuItem {
      guard let icon = action.icon else { return .separator() }
      let item = NSMenuItem(title: action.text, action: #selector(performMenuAction(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = action
      item.isEnabled = action.isEnabled
      item.state = action.isSelected ? .on : .off
      item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
      item.toolTip = action.helpText
      if let children = action.children { item.submenu = menu(for: children) }
      return item
    }

    private func menu(for actions: [PanelAction]) -> NSMenu {
      let menu = NSMenu()
      menu.autoenablesItems = false
      actions.forEach { menu.addItem(menuItem(for: $0)) }
      return menu
    }

    @objc private func performAction(_ sender: AnyObject) {
      let identifier: NSToolbarItem.Identifier?
      if let button = sender as? NSButton {
        identifier = button.identifier.map { NSToolbarItem.Identifier($0.rawValue) }
      } else {
        identifier = (sender as? NSToolbarItem)?.itemIdentifier
      }
      guard let identifier, let action = actions[identifier], action.isEnabled else { return }
      if let children = action.children, let button = sender as? NSButton {
        menu(for: children).popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY), in: button)
      } else {
        action.perform()
      }
    }

    @objc private func performMenuAction(_ sender: NSMenuItem) {
      guard let action = sender.representedObject as? PanelAction, action.isEnabled else { return }
      action.perform()
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator(panel: model.panel) }

  func makeNSView(context: Context) -> AttachmentView {
    context.coordinator.update(model, dock: dock)
    let view = AttachmentView(frame: .zero)
    view.windowChanged = { [weak coordinator = context.coordinator] in coordinator?.attach(to: $0) }
    return view
  }

  func updateNSView(_ nsView: AttachmentView, context: Context) {
    context.coordinator.update(model, dock: dock)
    context.coordinator.attach(to: nsView.window)
  }

  static func dismantleNSView(_ nsView: AttachmentView, coordinator: Coordinator) {
    coordinator.attach(to: nil)
  }
}
