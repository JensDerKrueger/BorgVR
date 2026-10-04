import SwiftUI

struct RenderControlsPanel: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var renderingParameters: RenderingParameters
  @EnvironmentObject private var appSettings: AppSettings
  @EnvironmentObject private var serverController: BackgroundServerController
  @EnvironmentObject private var sharePlay: SharePlayCoordinator
  @EnvironmentObject private var docking: DockingController
  @Environment(\.openWindow) private var openWindow

  let isDetachedWindow: Bool

  @State private var showLog = false
  @State private var showDatasetInfo = false
  @State private var selectedInteractionMode: AppModel.InteractionMode = .model
  @State private var copiedWebGPUShareLink = false
  @State private var showLeaveSharePlayConfirmation = false

  var body: some View {
    VStack(spacing: 8) {
      HStack {
        Button {
          requestDatasetClose()
        } label: {
          Image(systemName: "xmark")
        }
        .accessibilityLabel("Close")
        .help("Close")
        .buttonStyle(.borderedProminent)

        Spacer()

        Text(appModel.activeDataset?.description ?? "BorgVR")
          .font(.headline)
          .lineLimit(1)

        Spacer()

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
          sharePlay.isInSession
            ? String(localized: "SharePlay active")
            : String(localized: "Start SharePlay")
        )
        .buttonStyle(.bordered)

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
          .buttonStyle(.bordered)
        }

        if canCopyWebGPUShareLink {
          Button {
            copyWebGPUShareLink()
          } label: {
            Image(systemName: copiedWebGPUShareLink ? "checkmark" : "link")
          }
          .accessibilityLabel("Copy WebGPU link")
          .help("Copy WebGPU link")
          .buttonStyle(.bordered)
        }

        Button {
          showDatasetInfo.toggle()
        } label: {
          Image(systemName: "info.circle")
        }
        .accessibilityLabel("dataset_info_button")
        .help("dataset_info_button_help")
        .buttonStyle(.bordered)

        if appSettings.showLogButton {
          Button {
            showLog.toggle()
          } label: {
            Image(systemName: "text.alignleft")
          }
          .accessibilityLabel("Log")
          .help("Log")
          .buttonStyle(.bordered)
        }

        Button {
          openWindow(id: "PerformanceGraphView")
        } label: {
          Image(systemName: "chart.xyaxis.line")
        }
        .accessibilityLabel("performance_title")
        .help("performance_title")
        .buttonStyle(.bordered)

        DockToggleButton(panel: .renderControls)

        if !isDetachedWindow {
          Button {
            docking.hide(.renderControls)
          } label: {
            Image(systemName: "eye.slash")
          }
          .accessibilityLabel("Hide UI")
          .help("Hide UI")
          .buttonStyle(.bordered)
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
        Picker("Render Mode", selection: $renderingParameters.renderMode) {
          ForEach(RenderMode.allCases) { mode in
            Text(mode.description).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .onChange(of: renderingParameters.renderMode) { _, newMode in
          docking.hideIncompatibleEditor(for: newMode)
          sharePlay.synchronize(kind: .stateOnly)
        }

        HStack(spacing: 8) {
          if appSettings.showBrickVisualization {
            Toggle("Bricks", isOn: $renderingParameters.brickVis)
              .toggleStyle(.button)
              .fixedSize()
              .onChange(of: renderingParameters.brickVis) {
                sharePlay.synchronize(kind: .stateOnly)
              }
          }

          Button {
            renderingParameters.reset()
            sharePlay.synchronize(kind: .full)
            sharePlay.synchronize(kind: .transformOnly)
            sharePlay.flushSynchronization()
          } label: {
            Label("Reset", systemImage: "arrow.counterclockwise")
          }
          .fixedSize()
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
        if selectedInteractionMode != newValue {
          selectedInteractionMode = newValue
        }
      }

      if sharePlay.isInSession {
        HStack {
          Toggle(isOn: screenViewSynchronizationBinding) {
            Label("Synchronize View", systemImage: "link")
          }
          .toggleStyle(.button)
          .help("Keep this Mac's view synchronized with other iPhone, iPad, and Mac participants.")

          Spacer()
        }
      }

      modeWindowButtons
    }
    .padding(12)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    .sheet(isPresented: $showLog) {
      LoggerView(logger: appModel.logger)
    }
    .sheet(isPresented: $showDatasetInfo) {
      DatasetInfoView(
        dataset: appModel.activeDataset,
        metadata: appModel.activeDatasetMetadata
      ) {
        showDatasetInfo = false
      }
      .frame(minWidth: 420, minHeight: 360)
    }
    .onChange(of: appSettings.showLogButton) { _, isVisible in
      if !isVisible {
        showLog = false
      }
    }
    .alert("Leave SharePlay?", isPresented: $showLeaveSharePlayConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Leave SharePlay", role: .destructive) {
        closeDataset(leavingSharePlay: true)
      }
    } message: {
      Text("Closing this dataset will leave the current SharePlay session.")
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
    }
    .padding(4)
    .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Interaktion")
  }

  private func interactionModeSegment(
    _ mode: AppModel.InteractionMode,
    title: LocalizedStringKey,
    systemImage: String
  ) -> some View {
    let selected = selectedInteractionMode == mode
    let color = interactionModeColor(for: mode)

    return Button {
      selectedInteractionMode = mode
    } label: {
      HStack(spacing: 6) {
        Image(systemName: systemImage)
          .foregroundStyle(color)
        Text(title)
          .foregroundStyle(.primary)
      }
        .font(.callout)
        .fontWeight(selected ? .semibold : .regular)
        .lineLimit(1)
        .frame(maxWidth: .infinity, minHeight: 28)
        .padding(.horizontal, 5)
        .background(
          color.opacity(selected ? 0.22 : 0),
          in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private var modeWindowButtons: some View {
    GeometryReader { geometry in
      let spacing: CGFloat = 4
      let columnWidth = max(0, (geometry.size.width - spacing * 5) / 6)
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
      }
      .buttonStyle(.bordered)
    }
    .frame(height: 34)
  }

  private var lightingWindowButton: some View {
    Button {
      toggleWindow(.lightingEditor)
    } label: {
      windowButtonLabel("Lighting", systemImage: "lightbulb.max", color: .primary)
    }
    .help("Lighting")
  }

  private var editorWindowButton: some View {
    Button {
      docking.toggleEditor(for: renderingParameters.renderMode)
    } label: {
      windowButtonLabel("Editor", systemImage: "slider.horizontal.3", color: .purple)
    }
    .help("Editor")
  }

  private var objectWindowButton: some View {
    Button {
      toggleWindow(.markerEditor)
    } label: {
      windowButtonLabel("Objects", systemImage: "cube.transparent", color: .orange)
    }
    .help("Objects")
  }

  private var measurementWindowButton: some View {
    Button {
      toggleWindow(.measurementEditor)
    } label: {
      windowButtonLabel(
        "measurement_window_title",
        systemImage: "ruler",
        color: .green
      )
    }
    .help("measurement_window_title")
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

  private func interactionModeColor(for mode: AppModel.InteractionMode) -> Color {
    switch mode {
      case .model: .blue
      case .clipping: .cyan
      case .transferEditing: .purple
      case .drawing, .objectPlacement: .orange
      case .measurement: .green
    }
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

  private func requestDatasetClose() {
    if sharePlay.isInSession, !appModel.groupSessionHost {
      showLeaveSharePlayConfirmation = true
    } else {
      closeDataset(leavingSharePlay: false)
    }
  }

  private func closeDataset(leavingSharePlay: Bool) {
    if appSettings.autoloadTF,
       let fileURL = appModel.transferFunctionFileURL() {
      try? renderingParameters.transferFunction.save(to: fileURL)
    }
    if leavingSharePlay {
      sharePlay.leaveGroupActivity()
    } else {
      sharePlay.closeSharedDataset()
    }
    appModel.removeAllVolumeMarkers()
    appModel.removeAllVolumeMeasurements()
    docking.resetForDatasetClose()
    appModel.closeDataset(destination: .datasetSelection)
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
      transferFunction: renderingParameters.transferFunction,
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
