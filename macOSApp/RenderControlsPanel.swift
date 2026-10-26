import AppKit
import SwiftUI

private struct HeaderIconButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(.primary)
      .frame(width: 26, height: 24)
      .contentShape(Rectangle())
      .background(
        configuration.isPressed ? Color.primary.opacity(0.12) : .clear,
        in: RoundedRectangle(cornerRadius: 5)
      )
      .opacity(configuration.isPressed ? 0.65 : 1)
  }
}

struct RenderControlsPanel: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var renderingParameters: RenderingParameters
  @EnvironmentObject private var appSettings: AppSettings
  @EnvironmentObject private var serverController: BackgroundServerController
  @EnvironmentObject private var sharePlay: SharePlayCoordinator
  @EnvironmentObject private var session: ScreenBorgVRSession
  @EnvironmentObject private var docking: DockingController
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow

  let isDetachedWindow: Bool

  @State private var selectedInteractionMode: AppModel.InteractionMode = .model
  @State private var copiedWebGPUShareLink = false

  var body: some View {
    VStack(spacing: 8) {
      VolumeEditSynchronizationStatus(model: appModel.volumeBrush)
      HStack {
        Button {
          docking.request(.closeDataset)
        } label: {
          Image(systemName: "xmark")
        }
        .accessibilityLabel("Close")
        .help(MacKeyboardShortcut.help("Close", shortcut: .closeDataset))
        .buttonStyle(.borderedProminent)

        Spacer()

        Text(appModel.activeDataset?.description ?? "BorgVR")
          .font(.headline)
          .italic(appModel.isDatasetStreaming)
          .lineLimit(1)

        Spacer()

        headerActionGroup(tint: .green) {
          Button {
            sharePlay.startSharePlay()
          } label: {
            Image(systemName: "shareplay")
          }
          .accessibilityLabel(
            sharePlay.isInSession
              ? String(localized: "SharePlay active")
              : String(localized: "Start SharePlay")
          )
          .help(
            MacKeyboardShortcut.help(
              sharePlay.isInSession ? "SharePlay active" : "Start SharePlay",
              shortcut: .startSharePlay
            )
          )
          .buttonStyle(HeaderIconButtonStyle())

          if sharePlay.isInSession, !sharePlay.participants.isEmpty {
            Menu {
              ForEach(sharePlay.participants) { participant in
                Label(participant.displayName, systemImage: participant.platform.systemImage)
              }
            } label: {
              Image(systemName: "person.2")
            }
            .accessibilityLabel("Participants")
            .help("Participants")
            .buttonStyle(HeaderIconButtonStyle())
          }

          if canCopyWebGPUShareLink {
            Button {
              copyWebGPUShareLink()
            } label: {
              Image(systemName: copiedWebGPUShareLink ? "checkmark" : "link")
            }
            .accessibilityLabel("Copy WebGPU link")
            .help(MacKeyboardShortcut.help("Copy WebGPU link", shortcut: .copyWebGPULink))
            .buttonStyle(HeaderIconButtonStyle())
          }
        }

        headerActionGroup(tint: .teal) {
          Button {
            docking.request(.saveDatasetState)
          } label: {
            Image(systemName: "tray.and.arrow.down")
          }
          .accessibilityLabel("Save Dataset State")
          .help(MacKeyboardShortcut.help("Save Dataset State", shortcut: .saveDatasetState))
          .buttonStyle(HeaderIconButtonStyle())

          Button {
            docking.request(.restoreDatasetState)
          } label: {
            Image(systemName: "tray.and.arrow.up")
          }
          .accessibilityLabel("Restore Dataset State")
          .help(MacKeyboardShortcut.help("Restore Dataset State", shortcut: .restoreDatasetState))
          .buttonStyle(HeaderIconButtonStyle())
        }

        headerActionGroup(tint: .red) {
          Button {
            docking.request(.startRecording)
          } label: {
            Image(systemName: session.isCommandRecording ? "record.circle.fill" : "record.circle")
          }
          .disabled(session.isCommandRecording)
          .accessibilityLabel("Start Recording")
          .help(MacKeyboardShortcut.help("Start Recording", shortcut: .startRecording))
          .buttonStyle(HeaderIconButtonStyle())

          Button {
            docking.request(.stopRecording)
          } label: {
            Image(systemName: session.isCommandRecording ? "stop.circle.fill" : "stop.circle")
          }
          .disabled(!session.isCommandRecording)
          .accessibilityLabel("Stop and Save")
          .help(MacKeyboardShortcut.help("Stop and Save", shortcut: .stopRecording))
          .buttonStyle(HeaderIconButtonStyle())
        }

        headerActionGroup(tint: .blue) {
          Button {
            docking.showsDatasetInfo.toggle()
          } label: {
            Image(systemName: "info.circle")
          }
          .accessibilityLabel("dataset_info_button")
          .help(MacKeyboardShortcut.help("dataset_info_button_help", shortcut: .datasetInfo))
          .buttonStyle(HeaderIconButtonStyle())

          if appSettings.showLogButton {
            Button {
              docking.showsLog.toggle()
            } label: {
              Image(systemName: "text.alignleft")
            }
            .accessibilityLabel("Log")
            .help(MacRenderShortcut.help("Log", shortcut: .log))
            .buttonStyle(HeaderIconButtonStyle())
          }

          Button {
            openWindow(id: "PerformanceGraphView")
          } label: {
            Image(systemName: "chart.xyaxis.line")
          }
          .accessibilityLabel("performance_title")
          .help(MacRenderShortcut.help("performance_title", shortcut: .performance))
          .buttonStyle(HeaderIconButtonStyle())
        }

        headerActionGroup(tint: .gray) {
          Button {
            toggleRenderControlsDocking()
          } label: {
            Image(
              systemName: docking.isDetached(.renderControls)
                ? DockablePanelID.renderControls.detachedIcon
                : DockablePanelID.renderControls.dockedIcon
            )
          }
          .accessibilityLabel(
            docking.isDetached(.renderControls)
              ? String(localized: "Dock panel")
              : String(localized: "Detach panel")
          )
          .help(
            MacRenderShortcut.help(
              docking.isDetached(.renderControls) ? "Dock panel" : "Detach panel",
              shortcut: .docking
            )
          )
          .buttonStyle(HeaderIconButtonStyle())

          if !isDetachedWindow {
            Button {
              docking.hide(.renderControls)
            } label: {
              Image(systemName: "eye.slash")
            }
            .accessibilityLabel("Hide UI")
            .help(MacRenderShortcut.help("Hide UI", shortcut: .toggleControls))
            .buttonStyle(HeaderIconButtonStyle())
          }
        }
      }

      if sharePlay.showsSystemSharePlayJoinInstructions {
        Label(
          "To complete the connection, click Join in the green SharePlay menu in the menu bar.",
          systemImage: "shareplay"
        )
        .font(.callout.weight(.medium))
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
        .transition(.opacity)
      }

      HStack(spacing: 8) {
        if sharePlay.isInSession {
          Toggle(isOn: screenViewSynchronizationBinding) {
            Label("Synchronize View", systemImage: "link")
          }
          .toggleStyle(.button)
          .buttonStyle(ScreenControlButtonStyle(accent: .green, isSelected: sharePlay.isScreenViewSynchronized))
          .fixedSize()
          .help(MacKeyboardShortcut.help("Synchronize View", shortcut: .synchronizeView))
        }

        Picker("Render Mode", selection: renderModeBinding) {
          ForEach(RenderMode.allCases) { mode in
            Text(mode.description).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .help([
          MacRenderShortcut.help("Transfer Function", shortcut: .transferFunctionRendering),
          MacRenderShortcut.help("Transfer function + lighting", shortcut: .lightingRendering),
          MacRenderShortcut.help("Isovalue", shortcut: .isoRendering)
        ].joined(separator: " · "))

        if renderingParameters.renderMode == .isoValue {
          Button {
            docking.request(.render(.extractIsosurface))
          } label: {
            Image(systemName: "square.and.arrow.up")
          }
          .fixedSize()
          .accessibilityLabel("Extract Isosurface")
          .help(MacRenderShortcut.help("Extract Isosurface", shortcut: .extractIsosurface))
          .modifier(VolumeExportAvailability(model: appModel.volumeBrush))
        }

        HStack(spacing: 8) {
          if appSettings.showBrickVisualization {
            Toggle("Bricks", isOn: $renderingParameters.brickVis)
              .toggleStyle(.button)
              .buttonStyle(ScreenControlButtonStyle(isSelected: renderingParameters.brickVis))
              .fixedSize()
              .help(MacRenderShortcut.help("Bricks", shortcut: .bricks))
              .onChange(of: renderingParameters.brickVis) {
                session.commitExternalMutation(source: .userInterface, domain: .visualization)
                sharePlay.synchronize(kind: .stateOnly)
              }
          }

          Button {
            renderingParameters.reset()
            session.commitExternalMutation(source: .userInterface, domain: .visualization)
            sharePlay.synchronize(kind: .full)
            sharePlay.synchronize(kind: .transformOnly)
            sharePlay.flushSynchronization()
          } label: {
            Label("Reset", systemImage: "arrow.counterclockwise")
          }
          .fixedSize()
          .help(MacRenderShortcut.help("Reset", shortcut: .reset))
        }
        .padding(.leading, 12)
      }

      interactionModePicker
      .onAppear {
        selectedInteractionMode = appModel.interactionMode
      }
      .onChange(of: selectedInteractionMode) { _, newValue in
        applyInteractionModeSelection(newValue)
      }
      .onChange(of: appModel.interactionMode) { _, newValue in
        appModel.volumeBrush.context.finish(source: "pointer")
        appModel.endProjectedStrokeHandler?()
        if selectedInteractionMode != newValue {
          selectedInteractionMode = newValue
        }
      }

      modeWindowButtons
    }
    .padding(12)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    .onChange(of: appSettings.showLogButton) { _, isVisible in
      if !isVisible {
        docking.showsLog = false
      }
    }
  }

  private var interactionModePicker: some View {
    HStack(spacing: 4) {
      interactionModeSegment(.model, title: "Model", systemImage: "move.3d")
      interactionModeSegment(.clipping, title: "Clipping", systemImage: "viewfinder")
      interactionModeSegment(
        .transferEditing,
        title: "Transfer",
        systemImage: "slider.horizontal.3"
      )
      interactionModeSegment(.drawing, title: "Draw", systemImage: "scribble")
      interactionModeSegment(.objectPlacement, title: "Place", systemImage: "cube")
      interactionModeSegment(
        .measurement,
        title: "private_interaction_option_measurement",
        systemImage: "ruler"
      )
      interactionModeSegment(.volumeEditing, title: "Edit Volume", systemImage: "eraser")
    }
    .padding(4)
    .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Interaktion")
  }

  private func interactionModeSegment(
    _ mode: AppModel.InteractionMode,
    title: String,
    systemImage: String
  ) -> some View {
    let selected = selectedInteractionMode == mode
    let color = interactionModeColor(for: mode)

    return Button {
      selectedInteractionMode = mode
    } label: {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 6) {
          Image(systemName: systemImage).foregroundStyle(.primary)
          Text(LocalizedStringKey(title)).foregroundStyle(.primary)
        }
        .fixedSize(horizontal: true, vertical: false)
        Image(systemName: systemImage).foregroundStyle(.primary)
      }
        .font(.callout)
        .fontWeight(selected ? .semibold : .regular)
        .lineLimit(1)
        .frame(maxWidth: .infinity, minHeight: 28)
        .padding(.horizontal, 5)
        .background(ScreenControlAppearance.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
          RoundedRectangle(cornerRadius: 6)
            .strokeBorder(color.opacity(selected ? 1 : 0.3), lineWidth: selected ? 2 : 1)
        }
        .overlay(alignment: .bottom) {
          Capsule().fill(color).frame(width: 18, height: 2).padding(.bottom, 3)
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .help(interactionModeHelp(title: title, mode: mode))
    .accessibilityLabel(Text(LocalizedStringKey(title)))
    .overlay(alignment: .topTrailing) {
      if mode == .volumeEditing { VolumeBrushActivityIndicator(model: appModel.volumeBrush) }
    }
  }

  private var modeWindowButtons: some View {
    GeometryReader { geometry in
      let spacing: CGFloat = 4
      let columnWidth = max(0, (geometry.size.width - spacing * 6) / 7)
      let columnStride = columnWidth + spacing
      let doubleColumnWidth = columnWidth * 2 + spacing
      let groupInset: CGFloat = 8

      ZStack(alignment: .leading) {
        lightingWindowButton
          .frame(width: doubleColumnWidth - groupInset * 2)
          .offset(x: groupInset)

        editorWindowButton
          .frame(width: columnWidth)
          .offset(x: columnStride * 2)

        objectWindowButton
          .frame(width: doubleColumnWidth)
          .offset(x: columnStride * 3)

        measurementWindowButton
          .frame(width: columnWidth)
          .offset(x: columnStride * 5)

        brushWindowButton
          .frame(width: columnWidth)
          .offset(x: columnStride * 6)
      }
    }
    .frame(height: 34)
  }

  private var lightingWindowButton: some View {
    let isPresented = docking.isVisible(.lightingEditor)
    return Button {
      toggleWindow(.lightingEditor)
    } label: {
      windowButtonLabel(
        "Lighting",
        systemImage: "lightbulb.max",
        color: .primary
      )
    }
    .modifier(WindowPresentationButtonStyle(isPresented: isPresented, tint: .secondary))
    .accessibilityAddTraits(isPresented ? .isSelected : [])
    .help(MacRenderShortcut.help("Lighting", shortcut: .lighting))
  }

  private var editorWindowButton: some View {
    let panel: DockablePanelID = renderingParameters.renderMode == .isoValue
      ? .isoEditor
      : .transferFunctionEditor
    let isPresented = docking.isVisible(panel)
    return Button {
      docking.toggleEditor(for: renderingParameters.renderMode)
    } label: {
      windowButtonLabel(
        "Editor",
        systemImage: "slider.horizontal.3",
        color: .primary
      )
    }
    .modifier(WindowPresentationButtonStyle(isPresented: isPresented, tint: .purple))
    .accessibilityAddTraits(isPresented ? .isSelected : [])
    .help(MacRenderShortcut.help("Editor", shortcut: .editor))
  }

  private var objectWindowButton: some View {
    let isPresented = docking.isVisible(.markerEditor)
    return Button {
      toggleWindow(.markerEditor)
    } label: {
      windowButtonLabel(
        "Objects",
        systemImage: "cube.transparent",
        color: .primary
      )
    }
    .modifier(WindowPresentationButtonStyle(isPresented: isPresented, tint: .orange))
    .accessibilityAddTraits(isPresented ? .isSelected : [])
    .help(MacRenderShortcut.help("Objects", shortcut: .objects))
  }

  private var measurementWindowButton: some View {
    let isPresented = docking.isVisible(.measurementEditor)
    return Button {
      toggleWindow(.measurementEditor)
    } label: {
      windowButtonLabel(
        "measurement_window_title",
        systemImage: "ruler",
        color: .primary
      )
    }
    .modifier(WindowPresentationButtonStyle(isPresented: isPresented, tint: .green))
    .accessibilityAddTraits(isPresented ? .isSelected : [])
    .help(MacRenderShortcut.help("measurement_window_title", shortcut: .measurements))
  }

  private var brushWindowButton: some View {
    let isPresented = docking.isVisible(.volumeBrushEditor)
    return Button {
      toggleWindow(.volumeBrushEditor)
    } label: {
      windowButtonLabel("Brush", systemImage: "eraser", color: .primary)
    }
    .modifier(WindowPresentationButtonStyle(isPresented: isPresented, tint: .red))
    .accessibilityAddTraits(isPresented ? .isSelected : [])
    .help("Brush")
  }

  private func windowButtonLabel(
    _ title: LocalizedStringKey,
    systemImage: String,
    color: Color
  ) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 6) {
        Image(systemName: systemImage)
          .foregroundStyle(color)
        Text(title)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity)

      Image(systemName: systemImage)
        .foregroundStyle(color)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(title)
    }
  }

  private func toggleWindow(_ panel: DockablePanelID) {
    if docking.isDetached(panel) {
      openWindow(id: panel.windowID)
    } else {
      docking.toggleVisibility(panel)
    }
  }

  private func toggleRenderControlsDocking() {
    if docking.isDetached(.renderControls) {
      docking.dock(.renderControls)
      dismissWindow(id: DockablePanelID.renderControls.windowID)
    } else {
      docking.detach(.renderControls)
      openWindow(id: DockablePanelID.renderControls.windowID)
    }
  }

  private func headerActionGroup<Content: View>(
    tint: Color,
    @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(spacing: 0) {
      content()
    }
    .padding(2)
    .foregroundStyle(.primary)
    .background(ScreenControlAppearance.surface, in: Capsule())
    .overlay(Capsule().strokeBorder(tint.opacity(0.65), lineWidth: 1.5))
  }

  private func interactionModeColor(for mode: AppModel.InteractionMode) -> Color {
    switch mode {
      case .model: .blue
      case .clipping: .cyan
      case .transferEditing: .purple
      case .drawing, .objectPlacement: .orange
      case .measurement: .green
      case .volumeEditing: .red
    }
  }

  private func interactionModeHelp(
    title: String,
    mode: AppModel.InteractionMode
  ) -> String {
    let shortcut: MacRenderShortcut
    switch mode {
      case .model: shortcut = .model
      case .clipping: shortcut = .clipping
      case .transferEditing: shortcut = .transferInteraction
      case .drawing: shortcut = .drawing
      case .objectPlacement: shortcut = .placement
      case .measurement: shortcut = .measurement
      case .volumeEditing: shortcut = .volumeEditing
    }
    return MacRenderShortcut.help(title, shortcut: shortcut)
  }

  private func applyInteractionModeSelection(_ mode: AppModel.InteractionMode) {
    DispatchQueue.main.async {
      guard appModel.interactionMode != mode else { return }
      if mode != .measurement {
        appModel.clearVolumeMeasurementSelection()
      }
      appModel.interactionMode = mode
    }
  }

  private var screenViewSynchronizationBinding: Binding<Bool> {
    Binding(
      get: { sharePlay.isScreenViewSynchronized },
      set: { sharePlay.setScreenViewSynchronizationEnabled($0) }
    )
  }

  private var renderModeBinding: Binding<RenderMode> {
    Binding(
      get: { renderingParameters.renderMode },
      set: { newMode in
        guard newMode != renderingParameters.renderMode else { return }
        Task { @MainActor in
          await Task.yield()
          try? session.perform(.setRenderMode(newMode), source: .userInterface)
        }
      }
    )
  }

  private var canCopyWebGPUShareLink: Bool {
    guard let baseURL = serverController.shareableWebServerURL,
          let dataset = appModel.activeDataset,
          serverController.datasets.contains(where: {
            $0.id.caseInsensitiveCompare(dataset.uniqueId) == .orderedSame
          }) else {
      return false
    }

    return baseURL.scheme == "https"
  }

  private func shareableWebGPUURL() -> URL? {
    guard let baseURL = serverController.shareableWebServerURL,
          let dataset = appModel.activeDataset else {
      return nil
    }
    return WebGPUShareLink.datasetURL(
      baseURL: baseURL,
      datasetID: dataset.uniqueId,
      transferFunctions: Array(renderingParameters.activeTransferFunctions),
      renderMode: renderingParameters.renderMode,
      normalizedIsoValue: renderingParameters.normIsoValue
    )
  }

  private func copyWebGPUShareLink() {
    guard let url = shareableWebGPUURL() else { return }
    WebGPUShareLink.copyToPasteboard(url.absoluteString)
    copiedWebGPUShareLink = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
      copiedWebGPUShareLink = false
    }
  }
}

private struct WindowPresentationButtonStyle: ViewModifier {
  let isPresented: Bool
  let tint: Color

  func body(content: Content) -> some View {
    content.buttonStyle(ScreenControlButtonStyle(accent: tint, isSelected: isPresented, showsAccent: true))
  }
}
