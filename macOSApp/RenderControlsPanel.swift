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

  var body: some View {
    VStack(spacing: 8) {
      HStack {
        Button {
          closeDataset()
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

        ShareLink(
          item: BorgVRSharePlayActivity(),
          preview: SharePreview(String(localized: "BorgVR Live Collaboration"))
        ) {
          Image(systemName: "shareplay")
        }
        .simultaneousGesture(
          TapGesture().onEnded {
            sharePlay.markLocalActivityStarter()
          }
        )
        .accessibilityLabel(sharePlay.isInSession ? "SharePlay active" : "Start SharePlay")
        .help(sharePlay.isInSession ? "SharePlay active" : "Start SharePlay")
        .buttonStyle(.bordered)

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

        Button {
          showLog.toggle()
        } label: {
          Image(systemName: "text.alignleft")
        }
        .accessibilityLabel("Log")
        .help("Log")
        .buttonStyle(.bordered)

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

      Picker("Interaktion", selection: $selectedInteractionMode) {
        Text("Model").tag(AppModel.InteractionMode.model)
        Text("Clipping").tag(AppModel.InteractionMode.clipping)
        Text("Transfer").tag(AppModel.InteractionMode.transferEditing)
      }
      .pickerStyle(.segmented)
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

      HStack {
        Toggle("Bricks", isOn: $renderingParameters.brickVis)
          .toggleStyle(.button)
          .onChange(of: renderingParameters.brickVis) {
            sharePlay.synchronize(kind: .stateOnly)
          }

        Button {
          renderingParameters.reset()
          sharePlay.synchronize(kind: .full)
          sharePlay.synchronize(kind: .transformOnly)
          sharePlay.flushSynchronization()
        } label: {
          Label("Reset", systemImage: "arrow.counterclockwise")
        }

        Button {
          docking.toggleEditor(for: renderingParameters.renderMode)
        } label: {
          Label("Editor", systemImage: "slider.horizontal.3")
        }
      }
    }
    .padding(12)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    .sheet(isPresented: $showLog) {
      LoggerView(logger: appModel.logger)
    }
    .sheet(isPresented: $showDatasetInfo) {
      DatasetInfoView(dataset: appModel.activeDataset) {
        showDatasetInfo = false
      }
      .frame(minWidth: 420, minHeight: 360)
    }
  }

  private func applyInteractionModeSelection(_ mode: AppModel.InteractionMode) {
    DispatchQueue.main.async {
      guard appModel.interactionMode != mode else { return }
      appModel.interactionMode = mode
    }
  }

  private func closeDataset() {
    if appSettings.autoloadTF,
       let fileURL = appModel.transferFunctionFileURL() {
      try? renderingParameters.transferFunction.save(to: fileURL)
    }
    sharePlay.closeSharedDataset()
    docking.resetForDatasetClose()
    appModel.currentState = .selectData
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
