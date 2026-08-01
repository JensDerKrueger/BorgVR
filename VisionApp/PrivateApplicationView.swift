import SwiftUI

struct PrivateApplicationView: View {
  @Environment(RuntimeAppModel.self) private var runtimeAppModel
  @Environment(SharedAppModel.self) private var sharedAppModel

  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow

  @EnvironmentObject var storedAppModel: StoredAppModel
  @EnvironmentObject var voice: VoiceCommandService
  @EnvironmentObject var speech: SpeechHelper

  @State private var voiceHandler: VoiceCommandHandler?

  var body: some View {
    VStack() {
      Text("private_interaction_title")
        .font(.title)
        .bold()
        .padding()

      Picker(
        "private_interaction_picker_label",
        selection: Binding(
          get: { runtimeAppModel.interactionMode.rawValue },
          set: { (value: String) in
            switch value {
              case "model":
                runtimeAppModel.interactionMode = .model
              case "clipping":
                runtimeAppModel.interactionMode = .clipping
              default:
                break
            }
          }
        )
      ) {
        Text("private_interaction_option_model").tag("model")
        Text("private_interaction_option_clipping").tag("clipping")
      }
      .pickerStyle(.segmented)

      HStack {
        Button(action: openSelectedEditor) {
          Text(
            String(
              format: NSLocalizedString(
                "private_editor_title_format",
                comment: "Button title: '<render mode> Editor'"
              ),
              String(describing: sharedAppModel.renderMode)
            )
          )
        }
        .padding()

        Button("private_slicing_presets_button") {
          sharedAppModel.transferFunction.slicingPreset()
          runtimeAppModel.interactionMode = .clipping
          sharedAppModel.renderMode = .transferFunction1D
          sharedAppModel.synchronize(kind: .full)
        }
        .padding()
      }

      Spacer()

      VStack {
        Text("private_reset_section_title")
          .font(.title3)
          .bold()

        HStack {
          Button("private_reset_model_button") {
            sharedAppModel.resetModel()
            sharedAppModel.synchronize(kind: .full)
          }
          Button("private_reset_clipping_button") {
            sharedAppModel.resetClipBoundsToVolume()
            sharedAppModel.synchronize(kind: .full)
          }
          Button("private_reset_all_parameters_button") {
            sharedAppModel.reset()
            sharedAppModel.synchronize(kind: .full)
          }
        }
      }

      Spacer()

      if storedAppModel.enableVoiceInput {
        HStack() {
          Button(action: toggleVoice) {
            HStack(spacing: 10) {
              Image(
                systemName: voice.isEnabled ? "stop.circle.fill" : "mic.fill"
              )
              .font(.system(size: 18, weight: .semibold))

              Text(
                voice.isEnabled
                ? "private_voice_stop_button"
                : "private_voice_start_button"
              )
              .font(.headline)
              .contentTransition(.opacity)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(
              RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
          }
          .buttonStyle(.plain)
          .glassBackgroundEffect(in: .rect(cornerRadius: 24))
          .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
              .strokeBorder(
                voice.isEnabled ? (
                  voice.isPassive
                  ? Color.yellow.opacity(0.45)
                  : Color.red.opacity(0.45)
                )
                : Color.white.opacity(0.12),
                lineWidth: 2
              )
          )
          .shadow(radius: voice.isEnabled ? 14 : 6)
          .animation(
            .spring(response: 0.28, dampingFraction: 0.85),
            value: voice.isEnabled
          )
          .accessibilityLabel(
            voice.isEnabled
            ? NSLocalizedString(
              "private_voice_stop_label",
              comment: "Accessibility label: stop listening"
            )
            : NSLocalizedString(
              "private_voice_start_label",
              comment: "Accessibility label: start voice input"
            )
          )
          .onAppear {
            startupVoice()
          }

          Button(action: showVoiceHelp) {
            Image(systemName: "info.circle")
          }
        }
      }
    }
    .padding()
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

  private func showVoiceHelp() {
    openWindow(id: "VoiceCommandsView")
  }

  private func toggleVoice() {
    if voice.isEnabled {
      voice.stopListening()
      speak(
        NSLocalizedString(
          "private_voice_off",
          comment: "Spoken feedback when voice is turned off"
        )
      )
    } else {
      voice.startListening()
      speak(
        NSLocalizedString(
          "private_voice_on",
          comment: "Spoken feedback when voice is turned on"
        )
      )
    }
  }

  private func startupVoice() {
    voice.onMessage = { msg in
      switch msg {
        case .transcript(let text, let isFinal):
          handleVoiceCommand(text.lowercased(), isFinal: isFinal)
        case .stateChanged(let state):
          handleVoiceStateChange(state: state)
      }
    }

    switch voice.state {
      case .idle:
        voice.requestAuthorization(
          autostart: storedAppModel.enableVoiceInput
          && storedAppModel.autostartVoiceInput
        )
      case .failed(let error):
        runtimeAppModel.logger.warning(
          String(
            format: NSLocalizedString(
              "private_voice_usage_failed",
              comment: "Log: voice usage failed"
            ),
            String(describing: error)
          )
        )
        return
      case .denied(let error):
        runtimeAppModel.logger.warning(
          String(
            format: NSLocalizedString(
              "private_voice_usage_denied",
              comment: "Log: voice usage denied"
            ),
            String(describing: error)
          )
        )
        storedAppModel.enableVoiceInput = false
        return
      default:
        break
    }
  }

  private func handleVoiceCommand(_ text: String, isFinal: Bool) {
    let handler = ensureVoiceHandler()
    handler.handle(rawText: text, isFinal: isFinal)
  }

  private func handleVoiceStateChange(state: VoiceCommandService.State) {
    switch state {
      case .idle:
        break
      case .requestingAuth:
        break
      case .ready:
        break
      case .listening(_):
        break
      case .denied(let info):
        let messageDenied = String(
          format: NSLocalizedString(
            "private_voice_access_denied",
            comment: "Voice access denied (spoken/logged message)"
          ),
          info
        )
        speak(messageDenied)
        runtimeAppModel.logger.warning(messageDenied)
      case .failed(let info):
        let messageFailed = String(
          format: NSLocalizedString(
            "private_voice_failed",
            comment: "Voice failed (spoken/logged message)"
          ),
          info
        )
        speak(messageFailed)
        runtimeAppModel.logger.warning(messageFailed)
    }
  }

  func speak(_ text: String) {
    if storedAppModel.enableVoiceOutput {
      speech.speak(text)
    }
  }

  private func ensureVoiceHandler() -> VoiceCommandHandler {
    if let handler = voiceHandler {
      return handler
    }

    let handler = VoiceCommandHandler(
      runtimeAppModel: runtimeAppModel,
      sharedAppModel: sharedAppModel,
      voice: voice,
      speak: { message in
        speech.speak(message)
      },
      openSelectedEditor: {
        openSelectedEditor()
      }
    )
    voiceHandler = handler
    return handler
  }
}
