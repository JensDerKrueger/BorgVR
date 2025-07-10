import SwiftUI

struct RenderView: View {
  @Environment(AppModel.self) private var appModel
  @Environment(RenderingParamaters.self) private var renderingParamaters
  @EnvironmentObject var appSettings: AppSettings
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow

  @State private var graphTimer: FrameTimerProtocol? = nil

  var body: some View {
    VStack(spacing: 20) {
      Text("Render Options")
        .font(.title)
        .bold()

      Picker("Editor", selection: Binding(
        get: { renderingParamaters.renderMode },
        set: { newValue in
          renderingParamaters.renderMode = newValue
          openSelectedEditor()
        }
      )) {
        Text("Transfer Function with Lighting").tag(RenderMode.transferFunction1DLighting)
        Text("Transfer Function").tag(RenderMode.transferFunction1D)
        Text("Isovalue").tag(RenderMode.isoValue)
      }
      .pickerStyle(.segmented)
      .padding(.horizontal)

      HStack {
        // Button to open the selected editor
        Button(action: openSelectedEditor) {
          Text("Open " + String(describing: renderingParamaters.renderMode) + " Editor")
        }
        .padding()

        Button("Slicing Presets") {
          renderingParamaters.transferFunction.slicingPreset()
          appModel.interactionMode = .clipping
          renderingParamaters.renderMode = .transferFunction1D
        }

        Button("Reset all Parameters") {
          renderingParamaters.reset()
        }
        .padding()

      }

      Picker("Interaction", selection: Binding(
        get: { appModel.interactionMode.rawValue},
        set: { (value:String) in
          switch value {
            case "model":
              appModel.interactionMode = .model
            case "clipping":
              appModel.interactionMode = .clipping
            case "transferEditing":
              appModel.interactionMode = .transferEditing
            default:
              break
          }
        }
      )) {
        Text("Model").tag("model")
        Text("Clipping").tag("clipping")
        if renderingParamaters.renderMode == .transferFunction1D {
          Text("Transfer Function").tag("transferEditing")
        }
      }
      .pickerStyle(.segmented)

      Spacer()

      HStack {

        if appSettings.showProfiling {
          Button(action: openProfileView) {
            Text("Profiling Options")
              .font(.headline)
              .padding(.horizontal, 20)
              .padding(.vertical, 10)
          }
          .padding()
        }


        Button(action: closeDataset) {
          Text("Close Dataset")
            .font(.headline)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .background(
          RoundedRectangle(cornerRadius: 30)
            .fill(Color.red)
        )
        .foregroundColor(.white)
        .padding(.horizontal, 40)
      }
    }
    .onChange(of: scenePhase) { _, newPhase in
      Task { @MainActor in
        if newPhase == .background {
          closeDataset()
        }
      }
    }
    .onDisappear() {
      dismissWindow(id: "TransferFunctionEditorView")
      dismissWindow(id: "IsovalueEditorView")
      dismissWindow(id: "PerformanceGraphView")
      dismissWindow(id: "LoggerView")
      dismissWindow(id: "ProfileView")
    }
    .padding()
  }

  func openProfileView() {
    if !self.appModel.isViewOpen("ProfileView") {
      openWindow(id: "ProfileView")
    }
  }

  func openSelectedEditor() {
    let targetId = (renderingParamaters.renderMode == .isoValue)
    ? "IsovalueEditorView"
    : "TransferFunctionEditorView"

    let otherId = (renderingParamaters.renderMode == .isoValue)
    ? "TransferFunctionEditorView"
    : "IsovalueEditorView"

    if !self.appModel.isViewOpen(targetId) {
      openWindow(id: targetId)
    }

    if self.appModel.isViewOpen(otherId) {
      dismissWindow(id: otherId)
    }

  }

  func closeDataset() {
    Task { @MainActor in
      appModel.immersiveSpaceState = .inTransition
      await dismissImmersiveSpace()
      appModel.currentState = .selectData

      if appModel.datasetSource == .Local {
        if appSettings.autoloadTF {
          let tfFilename = URL(fileURLWithPath: appModel.activeDataset).deletingPathExtension().path()+".tf1d"
          let fileURL = URL(fileURLWithPath: tfFilename)
          try? renderingParamaters.transferFunction.save(to: fileURL)
        }

        if appSettings.autoloadTransform {
          let tfFilename = URL(fileURLWithPath: appModel.activeDataset).deletingPathExtension().path()+".trafo"
          let fileURL = URL(fileURLWithPath: tfFilename)
          try? renderingParamaters.transform.save(to: fileURL)
        }
      }

    }
  }
}
