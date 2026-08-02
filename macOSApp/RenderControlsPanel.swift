import SwiftUI

struct RenderControlsPanel: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var renderingParameters: RenderingParameters
  @EnvironmentObject private var appSettings: AppSettings
  @EnvironmentObject private var sharePlay: SharePlayCoordinator
  @EnvironmentObject private var docking: DockingController

  let isDetachedWindow: Bool

  @State private var showLog = false
  @State private var selectedInteractionMode: AppModel.InteractionMode = .model

  var body: some View {
    VStack(spacing: 8) {
      HStack {
        Button {
          closeDataset()
        } label: {
          Image(systemName: "xmark")
        }
        .accessibilityLabel("Schließen")
        .help("Schließen")
        .buttonStyle(.borderedProminent)

        Spacer()

        Text(appModel.activeDataset?.description ?? "BorgVR macOS")
          .font(.headline)
          .lineLimit(1)

        Spacer()

        ShareLink(
          item: BorgVRSharePlayActivity(),
          preview: SharePreview(String(localized: "BorgVR macOS Live Collaboration"))
        ) {
          Image(systemName: "shareplay")
        }
        .simultaneousGesture(
          TapGesture().onEnded {
            sharePlay.markLocalActivityStarter()
          }
        )
        .accessibilityLabel(sharePlay.isInSession ? "SharePlay aktiv" : "SharePlay starten")
        .help(sharePlay.isInSession ? "SharePlay aktiv" : "SharePlay starten")
        .buttonStyle(.bordered)

        Button {
          showLog.toggle()
        } label: {
          Image(systemName: "text.alignleft")
        }
        .accessibilityLabel("Log")
        .help("Log")
        .buttonStyle(.bordered)

        DockToggleButton(panel: .renderControls)

        if !isDetachedWindow {
          Button {
            docking.hide(.renderControls)
          } label: {
            Image(systemName: "eye.slash")
          }
          .accessibilityLabel("UI ausblenden")
          .help("UI ausblenden")
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
        Text("Modell").tag(AppModel.InteractionMode.model)
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
  }

  private func applyInteractionModeSelection(_ mode: AppModel.InteractionMode) {
    DispatchQueue.main.async {
      guard appModel.interactionMode != mode else { return }
      appModel.interactionMode = mode
    }
  }

  private func closeDataset() {
    if appModel.activeDataset?.source == .local,
       let identifier = appModel.activeDataset?.identifier,
       appSettings.autoloadTF {
      let fileURL = URL(fileURLWithPath: identifier).deletingPathExtension().appendingPathExtension("tf1d")
      try? renderingParameters.transferFunction.save(to: fileURL)
    }
    sharePlay.closeSharedDataset()
    docking.resetForDatasetClose()
    appModel.currentState = .selectData
  }
}
