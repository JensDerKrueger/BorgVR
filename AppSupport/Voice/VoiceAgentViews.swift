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
          Spacer()
          if (agent.busy && agent.collaborationQuestion == nil && agent.annotationDeletion == nil && !agent.userIsInteracting) || agent.connectionState == .connecting {
            ProgressView().controlSize(.small)
          }
          Button { agent.newConversation() } label: { Image(systemName: "arrow.counterclockwise") }
            .help(voiceAgentText("New conversation"))
            .accessibilityLabel(voiceAgentText("New conversation"))
        }
        if !agent.model.isEmpty { Text(agent.model).font(.caption).foregroundStyle(.secondary) }
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
                  }
                }
                .id(message.id)
              }
              ForEach(agent.ruleProposals) { proposal in
                VStack(alignment: .leading, spacing: 8) {
                  Text(proposal.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                  ViewThatFits(in: .horizontal) {
                    HStack { ruleActions(proposal) }
                    VStack(alignment: .leading) { ruleActions(proposal) }
                  }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
              }
            }
            .padding(.vertical, 8)
          }
          .frame(minHeight: 160)
          .onChange(of: agent.messages.count) { _, _ in
            if let last = agent.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
          }
        }
        if agent.collaborationQuestion != nil {
          ViewThatFits(in: .horizontal) {
            HStack { collaborationActions }
            VStack(alignment: .leading) { collaborationActions }
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
          .disabled(agent.interrupting || agent.connectionState == .connecting || !agent.isAvailable)
          TextField(voiceAgentText(agent.collaborationQuestion == nil ? "Message" : "Reply"), text: $text, axis: .vertical)
            .lineLimit(1...4).textFieldStyle(.roundedBorder)
            .disabled(agent.interrupting || speech.isRecording)
            .submitLabel(.send)
            .onSubmit { sendMessage() }
            .onKeyPress(.return, phases: .down) { key in
              guard key.modifiers.intersection([.shift, .control, .option, .command]).isEmpty else { return .ignored }
              sendMessage()
              return .handled
            }
          Button { sendMessage() } label: { Image(systemName: "arrow.up").frame(width: 28, height: 28) }
          .buttonStyle(.borderedProminent)
          .help(voiceAgentText(agent.collaborationQuestion != nil ? "Reply" : agent.busy ? "Send and interrupt current request" : "Send"))
          .accessibilityLabel(voiceAgentText(agent.collaborationQuestion != nil ? "Reply" : agent.busy ? "Send and interrupt current request" : "Send"))
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
    .onDisappear {
      speech.cancel()
      if let preview = agent.annotationDeletion { agent.resolveAnnotationDeletion(id: preview.id, accepted: false) }
    }
    .onChange(of: settings.enabled) { _, enabled in if !enabled { dismiss() } }
  }

  private var canSendMessage: Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= 8192 &&
      !agent.interrupting && !speech.isRecording && agent.connectionState != .connecting && agent.isAvailable
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

  @ViewBuilder private var collaborationActions: some View {
    Button(voiceAgentText("Yes"), systemImage: "checkmark") {
      Task { await agent.answerCollaboration(voiceAgentText("Yes")) }
    }.buttonStyle(.borderedProminent)
    Button(voiceAgentText("No"), systemImage: "xmark") {
      Task { await agent.answerCollaboration(voiceAgentText("No")) }
    }.buttonStyle(.bordered)
    Button(voiceAgentText("Continue without help"), systemImage: "play.fill") {
      Task { await agent.answerCollaboration(voiceAgentText("Please continue without additional hints.")) }
    }.buttonStyle(.bordered)
  }

  @ViewBuilder private func ruleActions(_ proposal: VoiceAgentQuestion) -> some View {
    Button(voiceAgentText("Remember rule"), systemImage: "brain.head.profile") {
      Task { await agent.decideRule(proposal, remember: true) }
    }.buttonStyle(.borderedProminent)
    Button(voiceAgentText("Discard"), systemImage: "xmark") {
      Task { await agent.decideRule(proposal, remember: false) }
    }.buttonStyle(.bordered)
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
  @State private var token = ""
  @State private var importsCertificate = false
  @State private var importing = false
  @State private var testing = false
  @State private var errorText: String?

  init(agent: VoiceAgentController) {
    self.agent = agent
    _settings = ObservedObject(wrappedValue: agent.settings)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Toggle(voiceAgentText("Enable AI assistant"), isOn: $settings.enabled)
      Text(voiceAgentText("The assistant sends your text, visualization state and, if allowed, render images to your configured server. It can change the current visualization. No camera or passthrough images are sent."))
        .font(.callout).foregroundStyle(.secondary)
      Divider()
      TextField(voiceAgentText("HTTPS server address"), text: $settings.address).textFieldStyle(.roundedBorder)
        #if !os(macOS)
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        #endif
      HStack {
        SecureField(voiceAgentText(settings.hasToken ? "Access token stored in Keychain" : "Access token"), text: $token)
          .textFieldStyle(.roundedBorder)
        Button {
          do { try settings.setToken(token); token = ""; errorText = nil }
          catch { errorText = error.localizedDescription }
        } label: { Image(systemName: "checkmark") }
          .buttonStyle(.bordered).disabled(token.isEmpty)
          .help(voiceAgentText("Save token"))
          .accessibilityLabel(voiceAgentText("Save token"))
        Button { importsCertificate = false; importing = true } label: { Image(systemName: "square.and.arrow.down") }
          .buttonStyle(.bordered).help(voiceAgentText("Import token file"))
          .accessibilityLabel(voiceAgentText("Import token file"))
        if settings.hasToken {
          Button {
            do { try settings.setToken("") } catch { errorText = error.localizedDescription }
          } label: { Image(systemName: "trash") }
            .buttonStyle(.bordered).help(voiceAgentText("Remove token"))
            .accessibilityLabel(voiceAgentText("Remove token"))
        }
      }
      HStack {
        Button(voiceAgentText("Import server certificate"), systemImage: "checkmark.shield") {
          importsCertificate = true; importing = true
        }
        .buttonStyle(.bordered)
        if !settings.certificate.isEmpty {
          Button { settings.removeCertificate() } label: { Image(systemName: "trash") }
            .buttonStyle(.bordered).help(voiceAgentText("Use system trust"))
            .accessibilityLabel(voiceAgentText("Use system trust"))
        }
      }
      if !settings.fingerprint.isEmpty {
        Text("SHA-256: " + settings.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        Text(voiceAgentText("System certificate trust")).font(.caption).foregroundStyle(.secondary)
      }
      Toggle(voiceAgentText("Share render images"), isOn: $settings.sharesImages)
      Toggle(voiceAgentText("Speak responses"), isOn: $settings.speaks)
      Stepper(value: $settings.workMinutes, in: 1...120) {
        HStack {
          Text(voiceAgentText("Maximum work time (minutes)"))
          Spacer()
          Text(settings.workMinutes, format: .number).monospacedDigit()
        }
      }
      Stepper(value: $settings.maximumCalls, in: 24...1024, step: 16) {
        HStack {
          Text(voiceAgentText("Maximum BorgVR calls"))
          Spacer()
          Text(settings.maximumCalls, format: .number).monospacedDigit()
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
      if !settings.knowledgeRules.isEmpty {
        Text(voiceAgentText("Remembered rules")).font(.headline)
        ForEach(settings.knowledgeRules) { rule in
          HStack(alignment: .top) {
            Text(rule.text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { settings.forgetRule(id: rule.id) } label: { Image(systemName: "trash") }
              .buttonStyle(.bordered)
              .help(voiceAgentText("Remove rule"))
              .accessibilityLabel(voiceAgentText("Remove rule"))
          }
        }
      }
      Text(voiceAgentText("If on-device-only recognition is disabled, Apple may process microphone audio. Audio is never sent to the BorgVR agent server."))
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button(voiceAgentText("Test server"), systemImage: "network") {
          testing = true
          Task {
            do { try await agent.testServer(); errorText = nil }
            catch { errorText = VoiceAgentError.connection.localizedDescription }
            testing = false
          }
        }
        .buttonStyle(.bordered).disabled(testing || !settings.hasToken)
        if testing { ProgressView().controlSize(.small) }
        Text(agent.status).foregroundStyle(.secondary)
      }
      if let error = errorText ?? agent.errorText { Text(error).foregroundStyle(.red).font(.callout) }
    }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
      do {
        guard let url = try result.get().first else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65536 else {
          throw VoiceAgentError.configuration
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: 65537) ?? Data()
        guard data.count <= 65536 else { throw VoiceAgentError.configuration }
        if importsCertificate { try settings.importCertificate(data) }
        else {
          guard let token = String(data: data, encoding: .utf8) else { throw VoiceAgentError.configuration }
          try settings.setToken(token)
        }
        errorText = nil
      } catch { errorText = VoiceAgentError.configuration.localizedDescription }
    }
  }
}
