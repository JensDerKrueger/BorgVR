import AppKit
import SwiftUI

struct DockableUtilityWindow<Content: View>: Scene {
  let panel: DockablePanelID
  let width: CGFloat
  let height: CGFloat
  @ViewBuilder var content: () -> Content

  var body: some Scene {
    BorgVRUtilityWindow(title: panel.title, id: panel.windowID, width: width, height: height, content: content)
  }
}

struct BorgVRUtilityWindow<Content: View>: Scene {
  let title: LocalizedStringKey
  let id: String
  let width: CGFloat
  let height: CGFloat
  @ViewBuilder var content: () -> Content

  var body: some Scene {
    UtilityWindow(title, id: id) {
      content()
        .windowFullScreenBehavior(.disabled)
    }
    .defaultSize(width: width, height: height)
    .windowResizability(.contentMinSize)
    .windowManagerRole(.associated)
    .windowToolbarStyle(.unifiedCompact)
    .restorationBehavior(.disabled)
    .commandsRemoved()
  }
}

private struct WindowFrameAutosaveAccessor: NSViewRepresentable {
  let name: String
  let didClose: () -> Void

  final class AccessorView: NSView {
    var movedToWindow: ((NSWindow?) -> Void)?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      movedToWindow?(window)
    }
  }

  @MainActor final class Coordinator: NSObject {
    weak var window: NSWindow?
    var didClose: () -> Void = {}

    func attach(to window: NSWindow?, name: String) {
      guard self.window !== window else { return }
      NotificationCenter.default.removeObserver(self)
      self.window = window
      guard let window else { return }
      window.tabbingMode = .disallowed
      DispatchQueue.main.async { [weak self, weak window] in
        guard let window, self?.window === window, window.frameAutosaveName != name else { return }
        _ = window.setFrameUsingName(name)
        _ = window.setFrameAutosaveName(name)
      }
      NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
        name: NSWindow.willCloseNotification, object: window)
    }

    @objc private func windowWillClose(_ notification: Notification) { didClose() }
    deinit { NotificationCenter.default.removeObserver(self) }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> AccessorView {
    let view = AccessorView(frame: .zero)
    context.coordinator.didClose = didClose
    view.movedToWindow = { [weak coordinator = context.coordinator] window in
      coordinator?.attach(to: window, name: name)
    }
    return view
  }

  func updateNSView(_ nsView: AccessorView, context: Context) {
    context.coordinator.didClose = didClose
    context.coordinator.attach(to: nsView.window, name: name)
  }

  static func dismantleNSView(_ nsView: AccessorView, coordinator: Coordinator) {
    coordinator.attach(to: nil, name: "")
  }
}

private extension View {
  func windowFrameAutosaveName(_ name: String, didClose: @escaping () -> Void) -> some View {
    background(WindowFrameAutosaveAccessor(name: name, didClose: didClose).frame(width: 0, height: 0))
  }
}

struct DockToggleButton: View {
  @EnvironmentObject private var docking: DockingController
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow

  let panel: DockablePanelID

  var body: some View {
    Button {
      if docking.isDetached(panel) {
        docking.dock(panel)
        dismissWindow(id: panel.windowID)
      } else {
        docking.detach(panel)
        openWindow(id: panel.windowID)
      }
    } label: {
      Image(systemName: docking.isDetached(panel) ? panel.detachedIcon : panel.dockedIcon)
    }
    .help(
      panel == .renderControls
        ? MacRenderShortcut.help(docking.isDetached(panel) ? "Dock panel" : "Detach panel", shortcut: .docking)
        : String(localized: docking.isDetached(panel) ? "Dock panel" : "Detach panel")
    )
    .accessibilityLabel(
      docking.isDetached(panel)
        ? String(localized: "Dock panel")
        : String(localized: "Detach panel")
    )
    .buttonStyle(PanelTitleButtonStyle())
  }
}

struct DetachedDockablePanel<Content: View>: View {
  @EnvironmentObject private var docking: DockingController

  let panel: DockablePanelID
  let minWidth: CGFloat
  let minHeight: CGFloat
  @ViewBuilder var content: () -> Content

  init(
    panel: DockablePanelID,
    minWidth: CGFloat = 360,
    minHeight: CGFloat = 180,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.panel = panel
    self.minWidth = minWidth
    self.minHeight = minHeight
    self.content = content
  }

  var body: some View {
    Group {
      if docking.isDetached(panel) && docking.isVisible(panel) {
        content()
          .frame(minWidth: minWidth, minHeight: minHeight)
      } else {
        Color.clear
          .frame(width: 1, height: 1)
      }
    }
    .windowFrameAutosaveName(panel.windowFrameAutosaveName) {
      docking.detachedWindowDidDisappear(panel)
    }
  }
}

struct DockableEditorPanel<Content: View>: View {
  @EnvironmentObject private var docking: DockingController
  @Environment(\.dismissWindow) private var dismissWindow
  @StateObject private var window: PanelWindow
  let panel: DockablePanelID
  let detached: Bool
  var onDragChanged: ((CGSize) -> Void)?
  var onDragEnded: (() -> Void)?
  @ViewBuilder var content: () -> Content

  init(
    panel: DockablePanelID,
    detached: Bool = false,
    onDragChanged: ((CGSize) -> Void)? = nil,
    onDragEnded: (() -> Void)? = nil,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.panel = panel
    self.detached = detached
    _window = StateObject(wrappedValue: PanelWindow(panel: panel))
    self.onDragChanged = onDragChanged
    self.onDragEnded = onDragEnded
    self.content = content
  }

  @ViewBuilder
  var body: some View {
    if detached {
      VStack(spacing: 0) {
        titleProgress
        content().padding(12)
          .environment(\.panelWindow, window)
      }
        .background(NativePanelToolbar(model: window) {
          docking.dock(panel)
          dismissWindow(id: panel.windowID)
        }.frame(width: 0, height: 0))
    } else {
      VStack(spacing: 0) {
        DockablePanelTitleBar(window: window, onDragChanged: onDragChanged, onDragEnded: onDragEnded)
        if window.configuration.titleProgress != nil { titleProgress }
        else { Divider() }
        content()
          .padding(12)
          .environment(\.panelWindow, window)
      }
      .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.12)))
      .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
    }
  }

  @ViewBuilder
  private var titleProgress: some View {
    if let progress = window.configuration.titleProgress {
      FractionProgressLine(fraction: progress.fraction, color: progress.color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progress.statusText)
        .help(progress.statusText)
    }
  }
}

private struct PanelTitleButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(.secondary)
      .frame(width: 26, height: 24)
      .background(configuration.isPressed ? Color.primary.opacity(0.16) : Color.primary.opacity(0.06),
        in: RoundedRectangle(cornerRadius: 4))
      .contentShape(Rectangle())
  }
}

private struct DockablePanelTitleBar: View {
  @EnvironmentObject private var docking: DockingController
  @Environment(\.dismissWindow) private var dismissWindow
  @ObservedObject var window: PanelWindow
  private var panel: DockablePanelID { window.panel }
  var onDragChanged: ((CGSize) -> Void)?
  var onDragEnded: (() -> Void)?

  private var title: some View {
    HStack {
      Text(window.title)
        .font(.headline.weight(window.configuration.titleFormat.isBold ? .semibold : .regular))
        .italic(window.configuration.titleFormat.isItalic)
        .foregroundStyle(window.titleColor)
        .lineLimit(1)
        .help(window.title)
      Spacer(minLength: 12)
    }
    .padding(.vertical, 10)
    .padding(.leading, 12)
    .contentShape(Rectangle())
  }

  var body: some View {
    HStack(spacing: 6) {
      if !window.configuration.leading.isEmpty {
        PanelActionButtons(items: window.configuration.leading)
          .padding(.leading, 8)
      }
      title.gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("dockablePanelCanvas"))
          .onChanged { onDragChanged?($0.translation) }
          .onEnded { _ in onDragEnded?() })
      PanelActionButtons(items: window.configuration.actions)
      DockToggleButton(panel: panel)
      Button {
        let wasDetached = docking.isDetached(panel)
        docking.close(panel)
        if wasDetached { dismissWindow(id: panel.windowID) }
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(PanelTitleButtonStyle())
      .help(panel == .renderControls
        ? MacRenderShortcut.help("Close panel", shortcut: .toggleControls) : String(localized: "Close panel"))
      .accessibilityLabel("Close panel")
    }
    .padding(.trailing, 8)
    .background(.primary.opacity(0.04))
  }
}

struct PositionedDockablePanel<Content: View>: View {
  @EnvironmentObject private var docking: DockingController
  let panel: DockablePanelID
  let containerSize: CGSize
  @ViewBuilder var content: () -> Content
  @State private var measuredSize: CGSize = .zero
  @State private var dragStart: CGPoint?

  private var origin: CGPoint {
    docking.origin(for: panel, panelSize: measuredSize, containerSize: containerSize)
  }

  var body: some View {
    DockableEditorPanel(panel: panel, onDragChanged: { translation in
      if dragStart == nil {
        dragStart = origin
        docking.bringToFront(panel)
      }
      guard let dragStart else { return }
      docking.move(panel, to: CGPoint(x: dragStart.x + translation.width, y: dragStart.y + translation.height),
        panelSize: measuredSize, containerSize: containerSize)
    }, onDragEnded: {
      docking.finishMoving(panel, panelSize: measuredSize, containerSize: containerSize)
      dragStart = nil
    }, content: content)
    .frame(width: min(panel.inlineWidth, max(240, containerSize.width - 32)),
      height: panel.inlineHeight(in: containerSize))
    .fixedSize(horizontal: false, vertical: true)
    .onGeometryChange(for: CGSize.self) { $0.size } action: { measuredSize = $0 }
    .overlay(alignment: .topLeading) {
      if dragStart != nil,
         let anchor = docking.snapCandidate(for: panel, panelSize: measuredSize, containerSize: containerSize) {
        let target = anchor.origin(panelSize: measuredSize, containerSize: containerSize)
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
          .frame(width: measuredSize.width, height: measuredSize.height)
          .offset(x: target.x - origin.x, y: target.y - origin.y)
          .allowsHitTesting(false)
      }
    }
    .offset(x: origin.x, y: origin.y)
    .zIndex(docking.zIndex(for: panel))
    .simultaneousGesture(TapGesture().onEnded { docking.bringToFront(panel) })
  }
}

