import SwiftUI

struct RenderView: View {
  @Environment(RuntimeAppModel.self) private var runtimeAppModel
  @Environment(SharedAppModel.self) private var sharedAppModel
  @EnvironmentObject var storedAppModel: StoredAppModel
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow

  @StateObject private var voice = VoiceCommandService()
  private var speech = SpeechHelper()

  var body: some View {
    VStack(spacing: 20) {
      Text("Render Options")
        .font(.title)
        .bold()

      Picker("Editor", selection: Binding(
        get: { sharedAppModel.renderMode },
        set: { newValue in
          sharedAppModel.renderMode = newValue
          sharedAppModel.synchronize(kind: .stateOnly)
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
          Text("Open " + String(describing: sharedAppModel.renderMode) + " Editor")
        }
        .padding()

        Button("Slicing Presets") {
          sharedAppModel.transferFunction.slicingPreset()
          runtimeAppModel.interactionMode = .clipping
          sharedAppModel.renderMode = .transferFunction1D
          sharedAppModel.synchronize(kind: .full)
        }

        Button("Reset all Parameters") {
          sharedAppModel.reset()
          sharedAppModel.synchronize(kind: .full)
        }
        .padding()

        if storedAppModel.enableVoiceInput {
          Button(action: toggleVoice) {
            HStack(spacing: 10) {
              Image(
                systemName: voice.isEnabled ? "stop.circle.fill" : "mic.fill"
              )
              .font(.system(size: 18, weight: .semibold))

              Text(voice.isEnabled ? "Stop Listening" : "Start Voice Input")
                .font(.headline)
                .contentTransition(.opacity)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
          }
          .buttonStyle(.plain)
          .glassBackgroundEffect(in: .rect(cornerRadius: 24))

          .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
              .strokeBorder(
                voice.isEnabled ? (
                  voice.isPassive ? Color.yellow
                    .opacity(0.45) : Color.red
                    .opacity(0.45)
                )
                            : Color.white.opacity(0.12),
                            lineWidth: 2
)
          )
          .shadow(radius: voice.isEnabled ? 14 : 6)
          .animation(.spring(response: 0.28, dampingFraction: 0.85), value: voice.isEnabled)
          .accessibilityLabel(voice.isEnabled ? "Stop Listening" : "Start Voice Input")
          .onAppear { startupVoice() }
        }
      }

      Picker("Interaction", selection: Binding(
        get: { runtimeAppModel.interactionMode.rawValue},
        set: { (value:String) in
          switch value {
            case "model":
              runtimeAppModel.interactionMode = .model
            case "clipping":
              runtimeAppModel.interactionMode = .clipping
            default:
              break
          }
        }
      )) {
        Text("Model").tag("model")
        Text("Clipping").tag("clipping")
      }
      .pickerStyle(.segmented)

      Spacer()

      HStack {

        if storedAppModel.showProfiling {
          Button(action: openProfileView) {
            Text("Profiling Options")
              .font(.headline)
              .padding(.horizontal, 20)
              .padding(.vertical, 10)
          }
          .padding()
        }

        ShareLink(
          item: BorgVRActivity(),
          preview: SharePreview("BorgVR Live Collaboration")
        ).padding()

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
        .padding()
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
      voice.stopListening()
    }
    .padding()
  }

  func openProfileView() {
    if !self.runtimeAppModel.isViewOpen("ProfileView") {
      openWindow(id: "ProfileView")
    }
  }

  func openSelectedEditor() {
    let targetId = (sharedAppModel.renderMode == .isoValue)
    ? "IsovalueEditorView"
    : "TransferFunctionEditorView"

    let otherId = (sharedAppModel.renderMode == .isoValue)
    ? "TransferFunctionEditorView"
    : "IsovalueEditorView"

    if !self.runtimeAppModel.isViewOpen(targetId) {
      openWindow(id: targetId)
    }

    if self.runtimeAppModel.isViewOpen(otherId) {
      dismissWindow(id: otherId)
    }

  }

  func closeDataset() {
    runtimeAppModel.immersiveSpaceIntent = .close
  }

  // MARK: - Voice Control

  private func startupVoice() {
    voice.onMessage = { msg in
      switch msg {
        case .transcript(let text, let isFinal):
          handleVoiceCommand(text.lowercased(), isFinal: isFinal)
        case .stateChanged(let state):
          handleVoiceStateChange(state:state)
      }
    }
    switch voice.state {
      case .idle :
        voice.requestAuthorization()
      case .failed(let error) :
        runtimeAppModel.logger.warning("Voice usage failed: \(error)")
        return
      case .denied(let error) :
        runtimeAppModel.logger.warning("Voice usage denied: \(error)")
        storedAppModel.enableVoiceInput = false
        return
      default:
        break
    }

    if storedAppModel.enableVoiceInput && storedAppModel.autostartVoiceInput {
      voice.startListening()
      voice.enterPassiveMode()
    }
  }

  private func toggleVoice() {
    if voice.isEnabled {
      voice.stopListening()
      say("Voice off")
    } else {
      voice.startListening()
      say("Voice on")
    }
  }

  private func handleVoiceStateChange(state: VoiceCommandService.State) {
    switch state {
      case .idle :
        break;
      case .requestingAuth :
        break;
      case .ready :
        break;
      case .listening(_) :
        break;
      case .denied(let info):
        say("Voice access denied because of \(info)")
        runtimeAppModel.logger.warning("Voice access denied because of \(info)")
      case .failed(let info):
        say("Voice failed because of \(info)")
        runtimeAppModel.logger.warning("Voice failed because of \(info)")
    }
  }

  private func handleVoiceCommand(_ text: String, isFinal: Bool) {

    if voice.isPassive {
      if text.hasSuffix("wake up") ||
         text.hasSuffix("resume"){
        voice.exitPassiveMode()
        say("All ears now")
      } else {
        return
      }
    }

    if text.hasSuffix("standby") ||
       text.hasSuffix("pause") {
      voice.enterPassiveMode()
      say("Standing by")
    }

    if text.hasSuffix("switch to clipping") {
      runtimeAppModel.interactionMode = .clipping
      say("Clipping")
    }
    if text.hasSuffix("switch to model")  {
      runtimeAppModel.interactionMode = .model
      say("Model")
    }
    if text.hasSuffix("disable voice") ||
        text.hasSuffix("stop voice") ||
        text.hasSuffix("end voice") ||
        text.hasSuffix("cancel voice") ||
        text.hasSuffix("halt voice") ||
        text.hasSuffix("abort voice") ||
        text.hasSuffix("leave me alone") {
      voice.stopListening()
      say("Voice off")
    }
    if text.hasSuffix("reset view") {
      sharedAppModel.reset()
      sharedAppModel.synchronize(kind: .full)
      say("View reset")
    }
    if text.hasSuffix("what am i looking at"){
      if let info = runtimeAppModel.activeDatasetInfo {

        let componentWord = info.componentCount == 1 ? "component" : "components"
        let byteWord = info.bytesPerComponent == 1 ? "byte" : "bytes"
        let sizeText = info.width == info.height && info.height == info.depth ? "\(info.width) cubed" : ( info.width == info.height ? "\(info.width) squared by \(info.depth)" : "\(info.width) by \(info.height) by \(info.depth)")

        let text = "You are looking at the dataset \(info.description). It is \(sizeText) in size, with \(info.componentCount) \(componentWord) of \(info.bytesPerComponent) \(byteWord) per voxel."

        say(text)
      }
    }
  }

  private func say(_ text: String) {
    if storedAppModel.enableVoiceOutput {
      speech.speak(text)
    }
  }

}

/*
 Copyright (c) 2025 Computer Graphics and Visualization Group, University of Duisburg-
 Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of this
 software and associated documentation files (the "Software"), to deal in the Software
 without restriction, including without limitation the rights to use, copy, modify,
 merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 permit persons to whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included in all copies
 or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
 CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR
 THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
