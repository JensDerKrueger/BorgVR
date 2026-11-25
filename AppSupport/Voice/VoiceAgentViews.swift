import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct VoiceAgentButton: View {
  @EnvironmentObject private var agent: VoiceAgentController
  @ObservedObject private var settings: VoiceAgentSettings
  private let fullWidth: Bool
  #if !os(iOS)
  @Environment(\.openWindow) private var openWindow
  #endif

  init(agent: VoiceAgentController, fullWidth: Bool = false) {
    _settings = ObservedObject(wrappedValue: agent.settings)
    self.fullWidth = fullWidth
  }

  var body: some View {
    if settings.enabled {
      Button {
        #if os(iOS)
        agent.isPresented = true
        #else
        openWindow(id: VoiceAgentView.windowID)
        #endif
      } label: {
        Label(voiceAgentText("AI Assistant"), systemImage: "mic")
          .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: fullWidth ? 32 : nil, alignment: .leading)
      }
      .buttonStyle(.bordered)
      .help(voiceAgentText("AI Assistant"))
    }
  }
}

struct VoiceAgentView: View {
  static let windowID = "VoiceAgent"
  @ObservedObject var agent: VoiceAgentController
  @ObservedObject private var speech: VoiceAgentSpeech
  @ObservedObject private var settings: VoiceAgentSettings
  @Environment(\.dismiss) private var dismiss
  @State private var text = ""
  @State private var pendingModelProfileID: UUID?
  @State private var pickerSelection: VoiceAgentFileSelection?
  @State private var filePickerPresented = false

  init(agent: VoiceAgentController) {
    self.agent = agent
    _speech = ObservedObject(wrappedValue: agent.speech)
    _settings = ObservedObject(wrappedValue: agent.settings)
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 12) {
        HStack {
          Label(agent.status, systemImage: agent.connectionState == .ready ? "checkmark.shield" : "network")
            .lineLimit(1)
          Spacer(minLength: 0)
          if (agent.busy && agent.annotationDeletion == nil && agent.editStateDeletion == nil &&
              agent.volumeEditApproval == nil) || agent.connectionState == .connecting {
            ProgressView().controlSize(.small)
          }
          modelMenu
          Button { agent.newConversation() } label: { Image(systemName: "arrow.counterclockwise") }
            .help(voiceAgentText("New conversation"))
            .accessibilityLabel(voiceAgentText("New conversation"))
        }
        if let job = agent.importStatus {
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Label(job.filename, systemImage: job.phase == .completed ? "checkmark.circle" : "square.and.arrow.down")
              Spacer()
              if job.phase == .running {
                Button { agent.cancelImport(id: job.id) } label: { Image(systemName: "stop.circle") }
                  .help(voiceAgentText("Cancel import"))
                  .accessibilityLabel(voiceAgentText("Cancel import"))
              }
            }
            if job.active { ProgressView(value: job.progress) }
            if job.phase == .cancelling { Text(voiceAgentText("Cancelling import…")) }
            if job.phase == .cancelled { Text(voiceAgentText("Import cancelled")) }
            if job.phase == .failed { Text(voiceAgentText("Import failed")).foregroundStyle(.red) }
            if let detail = job.detail { Text(detail).foregroundStyle(.secondary) }
          }
          .font(.callout)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let bricks = agent.volumeBrickStatus {
          Group {
            switch bricks {
              case .ready:
                Label(voiceAgentText("Edited bricks are ready"), systemImage: "checkmark.circle")
              case .pending(let count):
                ProgressView(count > 0
                  ? String(format: voiceAgentText("Edited bricks pending: %lld"), Int64(count))
                  : voiceAgentText("Finishing edited bricks…"))
                  .controlSize(.small)
            }
          }
          .font(.callout)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
              ForEach(agent.messages) { message in
                VStack(alignment: .leading, spacing: 4) {
                  HStack {
                    Text(voiceAgentText(message.user ? "You" : "BorgVR"))
                      .font(.caption.weight(.semibold)).foregroundStyle(message.user ? Color.accentColor : .secondary)
                    Spacer()
                    if !message.user { VoiceAgentCopyButton(text: message.text) }
                  }
                  if message.user {
                    Text(message.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                  } else {
                    VoiceAgentMarkdownText(message.text)
                    if let count = message.confirmedChanges {
                      Text(count == 0 ? voiceAgentText("No change applied") :
                        String(format: voiceAgentText("Confirmed changes: %lld"), Int64(count)))
                        .font(.caption).foregroundStyle(.secondary)
                    }
                  }
                }
                .id(message.id)
              }
            }
            .padding(.vertical, 8)
          }
          .frame(minHeight: 160)
          .onChange(of: agent.messages.count) { _, _ in
            if let last = agent.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
          }
        }
        if let step = agent.stepText {
          VStack(alignment: .leading, spacing: 2) {
            Text(voiceAgentText("Next step")).font(.caption.weight(.semibold))
            Text(verbatim: step).font(.callout).lineLimit(3).textSelection(.enabled)
          }
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let selection = agent.presentedFileSelection {
          HStack {
            Text(selection.title).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
              pickerSelection = selection
              filePickerPresented = true
            } label: {
              Label(voiceAgentText(selection.kind == .folder ? "Choose folder" : "Choose file"), systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            Button { agent.resolvePresentedFileSelection(id: selection.id, url: nil) } label: {
              Image(systemName: "xmark")
            }
            .help(voiceAgentText("Cancel"))
            .accessibilityLabel(voiceAgentText("Cancel"))
          }
        }
        if let error = agent.errorText {
          HStack(alignment: .top) {
            Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
            VoiceAgentCopyButton(text: error)
          }
        }
        if !speech.transcript.isEmpty, speech.isRecording {
          Text(speech.transcript).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
        Divider()
        HStack(alignment: .bottom, spacing: 12) {
          Button { Task { await agent.toggleMicrophone() } } label: {
            Image(systemName: speech.isRecording ? "stop.circle.fill" : "mic.fill").frame(width: 28, height: 28)
          }
          .buttonStyle(.bordered)
          .tint(speech.isRecording ? .red : .accentColor)
          .help(voiceAgentText(speech.isRecording ? "Finish speaking" : "Speak"))
          .accessibilityLabel(voiceAgentText(speech.isRecording ? "Finish speaking" : "Speak"))
          .disabled(agent.connectionState == .connecting || !agent.isAvailable)
          TextField(voiceAgentText("Message"), text: $text, axis: .vertical)
            .lineLimit(1...4).textFieldStyle(.roundedBorder)
            .disabled(speech.isRecording)
            .submitLabel(.send)
            .onSubmit { sendMessage() }
            .onKeyPress(.return, phases: .down) { key in
              guard key.modifiers.intersection([.shift, .control, .option, .command]).isEmpty else { return .ignored }
              sendMessage()
              return .handled
            }
          Button { sendMessage() } label: { Image(systemName: "arrow.up").frame(width: 28, height: 28) }
          .buttonStyle(.borderedProminent)
          .help(voiceAgentText(agent.busy ? "Send and interrupt current request" : "Send"))
          .accessibilityLabel(voiceAgentText(agent.busy ? "Send and interrupt current request" : "Send"))
          .disabled(!canSendMessage)
          Button { agent.cancel() } label: { Image(systemName: "xmark.circle").frame(width: 28, height: 28) }
            .buttonStyle(.bordered).help(voiceAgentText("Cancel"))
            .accessibilityLabel(voiceAgentText("Cancel"))
        }
      }
      .padding()
      .navigationTitle(voiceAgentText("AI Assistant"))
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(voiceAgentText("Close")) { speech.cancel(); dismiss() }
        }
      }
    }
    #if os(macOS)
    .frame(minWidth: 460, idealWidth: 580, minHeight: 440, idealHeight: 580)
    #elseif os(visionOS)
    .frame(width: 600, height: 580)
    #endif
    .task { await agent.connect() }
    .alert(voiceAgentText("Switch to another model?"), isPresented: Binding(
      get: { pendingModelProfileID != nil },
      set: { visible in if !visible { pendingModelProfileID = nil } }), presenting: pendingModelProfileID) { id in
        Button(voiceAgentText("Switch model"), role: .destructive) {
          if canSwitchModel { settings.selectProfile(id) }
        }
        Button(voiceAgentText("Cancel"), role: .cancel) {}
    } message: { _ in
      Text(voiceAgentText("Switching models clears the current conversation."))
    }
    .fileImporter(isPresented: $filePickerPresented,
                  allowedContentTypes: selectionContentTypes,
                  allowsMultipleSelection: false, onCompletion: { result in
      if let selection = pickerSelection {
        agent.resolvePresentedFileSelection(id: selection.id, url: (try? result.get())?.first)
      }
      pickerSelection = nil
    }, onCancellation: {
      if let selection = pickerSelection { agent.resolvePresentedFileSelection(id: selection.id, url: nil) }
      pickerSelection = nil
    })
    .alert(voiceAgentText(deletionTitle), isPresented: Binding(
      get: { agent.annotationDeletion != nil },
      set: { visible in
        if !visible, let preview = agent.annotationDeletion { agent.resolveAnnotationDeletion(id: preview.id, accepted: false) }
      }), presenting: agent.annotationDeletion) { preview in
        Button(voiceAgentText("Delete annotations"), role: .destructive) {
          agent.resolveAnnotationDeletion(id: preview.id, accepted: true)
        }
        Button(voiceAgentText("Cancel"), role: .cancel) { agent.resolveAnnotationDeletion(id: preview.id, accepted: false) }
      } message: { preview in
        Text(String(format: voiceAgentText("Markers: %lld. Measurements: %lld. Placed meshes are kept."),
                    Int64(preview.markerCount), Int64(preview.measurementCount)))
      }
    .alert(voiceAgentText("Delete saved edit state?"), isPresented: Binding(
      get: { agent.editStateDeletion != nil },
      set: { visible in
        if !visible, let preview = agent.editStateDeletion { agent.resolveEditStateDeletion(id: preview.id, accepted: false) }
      }), presenting: agent.editStateDeletion) { preview in
        Button(voiceAgentText("Delete edit state"), role: .destructive) {
          agent.resolveEditStateDeletion(id: preview.id, accepted: true)
        }
        Button(voiceAgentText("Cancel"), role: .cancel) { agent.resolveEditStateDeletion(id: preview.id, accepted: false) }
      } message: { preview in
        let label = preview.name.isEmpty ? voiceAgentText("Unnamed edit state") : preview.name
        Text(String(format: voiceAgentText("Delete “%@” (%@)? The original dataset and active edit state are kept."),
                    label, String(preview.stateID.uuidString.prefix(8))))
      }
    .alert(voiceAgentText(agent.volumeEditApproval?.erase == true ? "Erase this volume region?" : "Restore this volume region?"),
           isPresented: Binding(
             get: { agent.volumeEditApproval != nil },
             set: { visible in
               if !visible, let preview = agent.volumeEditApproval { agent.resolveVolumeEditApproval(id: preview.id, accepted: false) }
             }), presenting: agent.volumeEditApproval) { preview in
      Button(voiceAgentText(preview.erase ? "Erase region" : "Restore region"), role: preview.erase ? .destructive : nil) {
        agent.resolveVolumeEditApproval(id: preview.id, accepted: true)
      }
      Button(voiceAgentText("Always approve volume edits")) {
        agent.resolveVolumeEditApproval(id: preview.id, accepted: true, alwaysApprove: true)
      }
      Button(voiceAgentText("Cancel"), role: .cancel) { agent.resolveVolumeEditApproval(id: preview.id, accepted: false) }
    } message: { preview in
      Text(String(format: voiceAgentText("Brush stamps: %lld. Channels: %@. Bounds (XYZ in meters): %@ to %@. The original dataset is preserved."),
                  Int64(preview.sampleCount), preview.channels.map(String.init).joined(separator: ", "),
                  formatEditBounds(preview.boundsMinimumMeters), formatEditBounds(preview.boundsMaximumMeters)))
    }
    .onDisappear {
      speech.cancel()
      if let preview = agent.annotationDeletion { agent.resolveAnnotationDeletion(id: preview.id, accepted: false) }
      if let preview = agent.editStateDeletion { agent.resolveEditStateDeletion(id: preview.id, accepted: false) }
      if let preview = agent.volumeEditApproval { agent.resolveVolumeEditApproval(id: preview.id, accepted: false) }
      if let selection = agent.fileSelection { agent.resolveFileSelection(id: selection.id, url: nil) }
    }
    .onChange(of: settings.enabled) { _, enabled in if !enabled { dismiss() } }
  }

  private var canSwitchModel: Bool {
    !agent.busy && !speech.isRecording && agent.connectionState != .connecting
  }

  private var modelMenu: some View {
    let title = settings.selectedProfile.map(modelProfileTitle) ?? voiceAgentText("No model profiles")
    return Menu {
      ForEach(settings.profiles) { profile in
        Button {
          guard canSwitchModel, profile.id != settings.selectedProfileID else { return }
          if agent.messages.isEmpty { settings.selectProfile(profile.id) }
          else { pendingModelProfileID = profile.id }
        } label: {
          if profile.id == settings.selectedProfileID {
            Label(modelProfileTitle(profile), systemImage: "checkmark")
              .accessibilityAddTraits(.isSelected)
          } else {
            Text(verbatim: modelProfileTitle(profile))
          }
        }
      }
    } label: {
      Label(title, systemImage: "cpu").lineLimit(1)
    }
    .frame(maxWidth: 192)
    .layoutPriority(1)
    .disabled(settings.profiles.isEmpty || !canSwitchModel)
    .help(agent.model.isEmpty ? title : agent.model)
    .accessibilityLabel(voiceAgentText("Model profiles"))
    .accessibilityValue(title)
  }

  private func modelProfileTitle(_ profile: VoiceAgentProfile) -> String {
    let title = profile.title
    guard profile.provider == .openAI, !profile.model.isEmpty, profile.model != title else { return title }
    return "\(title) (\(profile.model))"
  }

  private var selectionContentTypes: [UTType] {
    switch pickerSelection?.kind {
      case .folder: [.folder]
      case .visualization: [.json]
      default: [.item]
    }
  }

  private func formatEditBounds(_ point: SIMD3<Double>) -> String {
    let numbers = (0..<3).map { point[$0].formatted(.number.precision(.significantDigits(1...4))) }
    return "(" + numbers.joined(separator: "; ") + ")"
  }

  private var canSendMessage: Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= 8192 &&
      !speech.isRecording && agent.connectionState != .connecting && agent.isAvailable
  }

  private var deletionTitle: String {
    switch agent.annotationDeletion?.scope {
      case "markers": return "Delete all markers?"
      case "measurements": return "Delete all measurements?"
      default: return "Delete all annotations?"
    }
  }

  private func sendMessage() {
    guard canSendMessage else { return }
    let message = text
    text = ""
    Task { await agent.submit(message) }
  }


}

private struct VoiceAgentCopyButton: View {
  let text: String
  @State private var copied = false

  var body: some View {
    Button {
      #if os(macOS)
      NSPasteboard.general.clearContents()
      copied = NSPasteboard.general.setString(text, forType: .string)
      #else
      UIPasteboard.general.string = text
      copied = true
      #endif
    } label: {
      Image(systemName: copied ? "checkmark" : "doc.on.doc")
        .frame(width: 24, height: 24)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .help(voiceAgentText(copied ? "Copied" : "Copy response"))
    .accessibilityLabel(voiceAgentText(copied ? "Copied" : "Copy response"))
    .disabled(text.isEmpty)
    .task(id: copied) {
      guard copied else { return }
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
      copied = false
    }
  }
}

struct VoiceAgentMarkdownText: View {
  private let markdown: VoiceAgentMarkdown

  init(_ text: String) { markdown = VoiceAgentMarkdown(text) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(markdown.blocks) { block in
        HStack(alignment: .top, spacing: 8) {
          if block.indentation > 0 {
            Text(block.marker ?? "").monospacedDigit().frame(minWidth: 16, alignment: .trailing)
          }
          if block.style == .quote { Rectangle().fill(.secondary).frame(width: 2) }
          ForEach(block.cells.indices, id: \.self) { index in
            Text(styled(block.cells[index]))
              .font(font(for: block.style))
              .frame(maxWidth: .infinity, alignment: .leading)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(.leading, CGFloat(max(0, block.indentation - 1)) * 16)
        .padding(block.style == .code ? 8 : 0)
        .background(block.style == .code ? Color.primary.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
      }
    }
    .textSelection(.enabled)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func font(for style: VoiceAgentMarkdown.Style) -> Font {
    switch style {
      case .heading(let level): level == 1 ? .title3.bold() : .headline
      case .code: .body.monospaced()
      case .tableHeader: .body.bold()
      default: .body
    }
  }

  private func styled(_ value: AttributedString) -> AttributedString {
    var value = value
    for run in value.runs where run.inlinePresentationIntent?.contains(.code) == true {
      value[run.range].font = .body.monospaced()
    }
    return value
  }
}

struct VoiceAgentSettingsView: View {
  @ObservedObject var agent: VoiceAgentController
  @ObservedObject private var settings: VoiceAgentSettings
  @State private var editingProfile: VoiceAgentProfile?
  @State private var importsKnowledge = false
  @State private var errorText: String?

  init(agent: VoiceAgentController) {
    self.agent = agent
    _settings = ObservedObject(wrappedValue: agent.settings)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Toggle(voiceAgentText("Enable AI assistant"), isOn: $settings.enabled)
      profileList
      Divider()
      DisclosureGroup(voiceAgentText("Assistant options")) {
        Toggle(voiceAgentText("Save and restore the assistant conversation"), isOn: $settings.savesConversation)
        if let error = agent.conversationStorageError {
          Text(error).font(.callout).foregroundStyle(.red)
        }
        Toggle(voiceAgentText("Confirm volume edits"), isOn: $settings.confirmsVolumeEdits)
        Toggle(voiceAgentText("Speak responses"), isOn: $settings.speaks)
        VStack(alignment: .leading, spacing: 4) {
          Text(voiceAgentText("Response length"))
          Picker(voiceAgentText("Response length"), selection: $settings.responseLength) {
            Text(voiceAgentText("Concise")).tag(VoiceAgentResponseLength.concise)
            Text(voiceAgentText("Normal")).tag(VoiceAgentResponseLength.standard)
            Text(voiceAgentText("Detailed")).tag(VoiceAgentResponseLength.detailed)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
        }
        Stepper(value: $settings.workMinutes, in: VoiceAgentSettings.workMinutesRange) {
          HStack {
            Text(voiceAgentText("Maximum work time (minutes)"))
            Spacer()
            Text(settings.workMinutes, format: .number).monospacedDigit()
          }
        }
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text(voiceAgentText("Speech rate"))
            Spacer()
            HStack(spacing: 4) {
              Text(settings.speechRateMultiplier, format: .number.precision(.fractionLength(2))).monospacedDigit()
              Text(verbatim: "\u{00D7}")
            }
            .fixedSize()
            Button { settings.speechRateMultiplier = VoiceAgentSpeechRate.defaultMultiplier } label: {
              Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
            .help(voiceAgentText("Default speech rate"))
            .accessibilityLabel(voiceAgentText("Default speech rate"))
          }
          Slider(value: $settings.speechRateMultiplier, in: VoiceAgentSpeechRate.range, step: 0.05)
            .accessibilityLabel(voiceAgentText("Speech rate"))
        }
        .disabled(!settings.speaks)
        Toggle(voiceAgentText("On-device speech recognition only"), isOn: $settings.onDeviceOnly)
        HStack {
          Button(voiceAgentText("Import knowledge package"), systemImage: "doc.badge.plus") {
            importsKnowledge = true
          }
          .buttonStyle(.bordered)
          if settings.customKnowledge != nil {
            Button { try? settings.selectKnowledge(nil) } label: { Image(systemName: "arrow.counterclockwise") }
              .buttonStyle(.bordered).help(voiceAgentText("Restore bundled knowledge"))
              .accessibilityLabel(voiceAgentText("Restore bundled knowledge"))
          }
        }
        Text(voiceAgentText("If on-device-only recognition is disabled, Apple may process microphone audio. Audio is never sent to the model server."))
          .font(.caption).foregroundStyle(.secondary)
      }
      if let errorText { Text(errorText).foregroundStyle(.red).font(.callout) }
    }
    .sheet(item: $editingProfile) { profile in
      VoiceAgentModelProfileEditor(settings: settings, profile: profile)
    }
    .fileImporter(isPresented: $importsKnowledge, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
      do {
        guard let url = try result.get().first else { return }
        let limit = 128 * 1024
        let data = try VoiceAgentModelProfileEditor.readFile(url, limit: limit)
        try settings.selectKnowledge(data)
        errorText = nil
      } catch { errorText = error.localizedDescription }
    }
  }

  private var profileList: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(voiceAgentText("Model profiles")).font(.headline)
        Spacer()
        Button { editingProfile = .init(provider: .vllm, name: "") } label: {
          Image(systemName: "plus")
        }
        .buttonStyle(.bordered)
        .help(voiceAgentText("Add model profile"))
        .accessibilityLabel(voiceAgentText("Add model profile"))
        .disabled(settings.profiles.count >= VoiceAgentSettings.maximumProfiles)
      }
      ForEach(settings.profiles) { profile in
        let selected = settings.selectedProfileID == profile.id
        HStack(spacing: 8) {
          Button { settings.selectProfile(profile.id) } label: {
            HStack(spacing: 8) {
              Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
              Text(profile.title).lineLimit(1)
              Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .frame(minHeight: 36)
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(selected ? .isSelected : [])
          Button { editingProfile = profile } label: { Image(systemName: "pencil") }
            .buttonStyle(.bordered)
            .help(voiceAgentText("Edit model profile"))
            .accessibilityLabel(voiceAgentText("Edit model profile") + ": " + profile.title)
          Button(role: .destructive) {
            do { try settings.removeProfile(profile.id); errorText = nil }
            catch { errorText = error.localizedDescription }
          } label: { Image(systemName: "trash") }
          .buttonStyle(.bordered)
          .help(voiceAgentText("Remove model profile"))
          .accessibilityLabel(voiceAgentText("Remove model profile") + ": " + profile.title)
        }
      }
    }
  }
}
