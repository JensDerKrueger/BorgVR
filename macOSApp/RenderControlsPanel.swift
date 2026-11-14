import AppKit
import SwiftUI


struct RenderControlsPanel: View {
  @Environment(\.colorScheme) private var colorScheme
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var renderingParameters: RenderingParameters
  @EnvironmentObject private var appSettings: AppSettings
  @EnvironmentObject private var serverController: BackgroundServerController
  @EnvironmentObject private var sharePlay: SharePlayCoordinator
  @EnvironmentObject private var session: ScreenBorgVRSession
  @EnvironmentObject private var docking: DockingController
  @Environment(\.openWindow) private var openWindow

  @State private var selectedInteractionMode: AppModel.InteractionMode = .model
  @State private var copiedWebGPUShareLink = false
  @State private var pendingModeReset: AppModel.InteractionMode?

  private var displayedRenderModeIDs: [UInt8] {
    interfaceVisibility.displayedRenderModeIDs(
      active: renderingParameters.renderMode.rawValue, inSharePlay: sharePlay.isInSession)
  }

  private var interfaceVisibility: InterfaceVisibility {
    appSettings.interfaceVisibility.forDataset(supportsTransferFunctions:
      appModel.activeDatasetMetadata.map { $0.channelInterpretation == .independentChannels } ?? true)
  }

  var body: some View {
    VStack(spacing: 8) {
      VolumeEditSynchronizationStatus(model: appModel.volumeBrush)

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

        if let interpretation = appModel.activeDatasetMetadata?.channelInterpretation,
           interpretation != .independentChannels {
          Label(interpretation.colorInterpretation == .rgb ? "RGB" : "RGBA", systemImage: "photo")
        } else if displayedRenderModeIDs.count > 1 {
        Picker("Render Mode", selection: renderModeBinding) {
          ForEach(RenderMode.allCases.filter { displayedRenderModeIDs.contains($0.rawValue) }) { mode in
            Text(mode.description)
              .tag(mode)
              .disabled(!interfaceVisibility.renderModeIDs.contains(mode.rawValue))
          }
        }
        .pickerStyle(.segmented)
        .help([
          MacRenderShortcut.help("Transfer Function", shortcut: .transferFunctionRendering),
          MacRenderShortcut.help("Transfer function + lighting", shortcut: .lightingRendering),
          MacRenderShortcut.help("Isovalue", shortcut: .isoRendering)
        ].joined(separator: " · "))
        }

        if renderingParameters.renderMode == .isoValue,
           appModel.activeDatasetMetadata?.channelInterpretation == .independentChannels {
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
            Toggle("Bricks", isOn: Binding(get: { renderingParameters.brickVis },
              set: { try? session.perform(.setBrickVisualization(enabled: $0), source: .userInterface) }))
              .toggleStyle(.button)
              .buttonStyle(ScreenControlButtonStyle(isSelected: renderingParameters.brickVis))
              .fixedSize()
              .help(MacRenderShortcut.help("Bricks", shortcut: .bricks))
          }

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
    .panelActions(mainPanelConfiguration)
    .onChange(of: appSettings.showLogButton) { _, isVisible in
      if !isVisible {
        docking.showsLog = false
      }
    }
    .alert(resetTitle(for: pendingModeReset), isPresented: Binding(
      get: { pendingModeReset != nil },
      set: { if !$0 { pendingModeReset = nil } }
    ), presenting: pendingModeReset) { mode in
      Button("Cancel", role: .cancel) {}
      Button(resetConfirmationLabel(for: mode), role: .destructive) {
        performModeReset(mode)
      }
    } message: { mode in
      Text(resetMessage(for: mode))
    }
  }

  @ViewBuilder
  private var interactionModePicker: some View {
    if interfaceVisibility.interactionModes.count > 1
      || appSettings.showModeResetButtons
    {
      VStack(spacing: 2) {
        if appSettings.showModeResetButtons {
          HStack(spacing: 4) {
            ForEach(interfaceVisibility.interactionModes) { option in
              if let mode = AppModel.InteractionMode(rawValue: option.rawValue) {
                if mode == .volumeEditing {
                  VolumeEditResetButton(model: appModel.volumeBrush).frame(maxWidth: .infinity)
                } else {
                  modeResetButton(mode, title: resetTitle(for: mode))
                }
              }
            }
          }
        }
        if interfaceVisibility.interactionModes.count > 1 {
          HStack(spacing: 4) {
            ForEach(interfaceVisibility.interactionModes) { option in
              if let mode = AppModel.InteractionMode(rawValue: option.rawValue) {
                interactionModeSegment(mode, title: option.title, systemImage: option.icon)
              }
            }
          }
        }
      }
      .padding(4)
      .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Interaktion")
    }
  }

  private func modeResetButton(_ mode: AppModel.InteractionMode, title: LocalizedStringKey)
    -> some View
  {
    Button {
      pendingModeReset = mode
    } label: {
      Image(systemName: "arrow.counterclockwise")
        .foregroundStyle(interactionModeColor(for: mode))
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity)
    .help(Text(title))
    .accessibilityLabel(Text(title))
  }

  private func resetTitle(for mode: AppModel.InteractionMode?) -> LocalizedStringKey {
    switch mode {
      case .model: "Reset Model?"
      case .clipping: "Reset Clipping?"
      case .transferEditing:
        renderingParameters.renderMode == .isoValue ? "Reset Isovalue?" : "Reset Transfer Function?"
      case .drawing, .objectPlacement: "Delete All Objects?"
      case .measurement: "measurement_delete_all_confirmation_title"
      default: "Reset"
    }
  }

  private func resetConfirmationLabel(for mode: AppModel.InteractionMode) -> LocalizedStringKey {
    switch mode {
      case .drawing, .objectPlacement: "Delete All Objects"
      case .measurement: "measurement_delete_all_confirmation_delete"
      default: "Reset"
    }
  }

  private func resetMessage(for mode: AppModel.InteractionMode) -> LocalizedStringKey {
    switch mode {
      case .model: "Do you really want to reset the model transformation?"
      case .clipping: "Do you really want to reset the clipping bounds?"
      case .transferEditing:
        renderingParameters.renderMode == .isoValue
          ? "Do you really want to reset the isovalue?"
          : "Do you really want to reset the current transfer function?"
      case .drawing, .objectPlacement: "This removes every annotation object from the current session."
      case .measurement: "measurement_delete_all_confirmation_message"
      default: "Reset"
    }
  }

  private func performModeReset(_ mode: AppModel.InteractionMode) {
    let command: BorgVRCommand
    switch mode {
      case .model: command = .reset(.transform)
      case .clipping: command = .reset(.clipping)
      case .transferEditing:
        command = renderingParameters.renderMode == .isoValue ? .setNormalizedIsoValue(0.1) : .reset(.transferFunction)
      case .drawing, .objectPlacement: command = .clearObjects
      case .measurement: command = .clearMeasurements
      case .volumeEditing: return
    }
    do {
      try session.perform(command, source: .userInterface)
      sharePlay.flushSynchronization()
    } catch { appModel.logger.error(error.localizedDescription) }
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

  @ViewBuilder
  private var modeWindowButtons: some View {
    if interfaceVisibility.hasScreenPanels {
      if interfaceVisibility.isCustomized {
        HStack(spacing: 4) {
          if interfaceVisibility.showsScreenPanel(.lighting) { lightingWindowButton }
          if interfaceVisibility.showsScreenPanel(.transfer) { editorWindowButton }
          if interfaceVisibility.showsScreenPanel(.objects) { objectWindowButton }
          if interfaceVisibility.showsScreenPanel(.measurements) { measurementWindowButton }
          if interfaceVisibility.showsScreenPanel(.brush) { brushWindowButton }
        }
        .frame(height: 34)
      } else {
        GeometryReader { geometry in
          let spacing: CGFloat = 4
          let columnWidth = max(0, (geometry.size.width - spacing * 6) / 7)
          let columnStride = columnWidth + spacing
          let doubleColumnWidth = columnWidth * 2 + spacing
          let groupInset: CGFloat = 8

          ZStack(alignment: .leading) {
            lightingWindowButton
              .disabled(
                appModel.activeDatasetMetadata?.channelInterpretation != .independentChannels
              )
              .frame(width: doubleColumnWidth - groupInset * 2)
              .offset(x: groupInset)

            editorWindowButton
              .disabled(
                appModel.activeDatasetMetadata?.channelInterpretation != .independentChannels
              )
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
    }
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
    .disabled(appModel.activeDatasetMetadata?.channelInterpretation != .independentChannels)
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
    .disabled(appModel.activeDatasetMetadata?.channelInterpretation != .independentChannels)
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
    .help(MacRenderShortcut.help("Brush", shortcut: .brush))
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

  private var mainPanelConfiguration: PanelWindowConfiguration {
    var additional: [PanelAction] = [
      .button("shareplay", icon: "shareplay", text: String(localized: "Start SharePlay"),
        selected: sharePlay.isInSession, tint: .green,
        shortcutHint: MacKeyboardShortcut.startSharePlay.displayName) { sharePlay.startSharePlay() }
    ]
    if sharePlay.isInSession, !sharePlay.participants.isEmpty {
      additional.append(.menu("participants", icon: "person.2", text: String(localized: "Participants"),
        items: sharePlay.participants.map { participant in
          .button(participant.id.uuidString, icon: participant.platform.systemImage,
            text: participant.displayName, enabled: false, action: {})
        }))
    }
    if canCopyWebGPUShareLink {
      additional.append(.button("web-link", icon: copiedWebGPUShareLink ? "checkmark" : "link",
        text: String(localized: "Copy WebGPU link"),
        shortcutHint: MacKeyboardShortcut.copyWebGPULink.displayName, action: copyWebGPUShareLink))
    }
    additional += [.spacer("recording"),
      .button("record", icon: session.isCommandRecording ? "record.circle.fill" : "record.circle",
        text: String(localized: "Start Recording"), enabled: !session.isCommandRecording, tint: .red,
        shortcutHint: MacKeyboardShortcut.startRecording.displayName) {
          docking.request(.startRecording)
        },
      .button("stop", icon: session.isCommandRecording ? "stop.circle.fill" : "stop.circle",
        text: String(localized: "Stop and Save"), enabled: session.isCommandRecording, tint: .red,
        shortcutHint: MacKeyboardShortcut.stopRecording.displayName) {
          docking.request(.stopRecording)
        },
      .spacer("information"),
      .button("info", icon: "info.circle", text: String(localized: "dataset_info_button"),
        shortcutHint: MacKeyboardShortcut.datasetInfo.displayName) {
        docking.showsDatasetInfo.toggle()
      }]
    if appSettings.showLogButton {
      additional.append(.button("log", icon: "text.alignleft", text: String(localized: "Log"),
        shortcutHint: MacRenderShortcut.log.displayName) {
        docking.showsLog.toggle()
      })
    }
    if appSettings.showPerformanceButton {
      additional.append(.button("performance", icon: "chart.xyaxis.line", text: String(localized: "performance_title"),
      shortcutHint: MacRenderShortcut.performance.displayName) {
      openWindow(id: "PerformanceGraphView")
    })
    }
    return .standard(title: appModel.activeDataset?.description ?? "BorgVR",
      titleFormat: .init(
        color: appModel.isDatasetStreaming
          ? ScreenControlAppearance.datasetTitleColor(isStreaming: true, colorScheme: colorScheme) : nil,
        isItalic: appModel.isDatasetStreaming),
      titleProgress: appModel.isDatasetStreaming
        ? PanelTitleProgress(fraction: appModel.datasetStreaming.fractionRemaining,
          statusText: appModel.datasetStreaming.statusText) : nil,
      reset: .button("reset", icon: "arrow.counterclockwise", text: String(localized: "Reset"),
        shortcutHint: MacRenderShortcut.reset.displayName) {
        try? session.perform(.reset(.all), source: .userInterface)
        sharePlay.flushSynchronization()
      },
      load: .button("load", icon: "tray.and.arrow.up", text: String(localized: "Restore Dataset State"),
        shortcutHint: MacKeyboardShortcut.restoreDatasetState.displayName) {
        docking.request(.restoreDatasetState)
      },
      save: .button("save", icon: "tray.and.arrow.down", text: String(localized: "Save Dataset State"),
        shortcutHint: MacKeyboardShortcut.saveDatasetState.displayName) {
        docking.request(.saveDatasetState)
      },
      additional: additional,
      leading: [.button("close-dataset", icon: "xmark", text: String(localized: "Close Dataset"), tint: .red,
        shortcutHint: MacKeyboardShortcut.closeDataset.displayName) {
        docking.request(.closeDataset)
      }])
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
        guard interfaceVisibility.renderModeIDs.contains(newMode.rawValue),
              newMode != renderingParameters.renderMode else { return }
        Task { @MainActor in
          await Task.yield()
          guard interfaceVisibility.renderModeIDs.contains(newMode.rawValue) else { return }
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
