import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

struct VoiceAgentModelProfileEditor: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var settings: VoiceAgentSettings
  @State private var profile: VoiceAgentProfile
  @State private var token = ""
  @State private var removeToken = false
  @State private var importsCertificate = false
  @State private var importing = false
  @State private var test: Task<Void, Never>?
  @State private var testedModel: String?
  @State private var errorText: String?

  init(settings: VoiceAgentSettings, profile: VoiceAgentProfile) {
    self.settings = settings
    _profile = State(initialValue: profile)
  }

  private var isNew: Bool { !settings.profiles.contains { $0.id == profile.id } }
  private var savedToken: Bool { !removeToken && settings.hasSavedToken(for: profile) }
  private var tokenOverride: String? {
    let typed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    return typed.isEmpty ? (removeToken ? "" : nil) : typed
  }

  var body: some View {
    NavigationStack {
      Form {
        TextField(voiceAgentText("Profile name"), text: $profile.name)
        if isNew {
          Picker(voiceAgentText("Model provider"), selection: $profile.provider) {
            Text("vLLM").tag(VoiceAgentModelProvider.vllm)
            Text("OpenAI").tag(VoiceAgentModelProvider.openAI)
          }
        } else {
          LabeledContent(voiceAgentText("Model provider"), value: profile.provider == .openAI ? "OpenAI" : "vLLM")
        }
        TextField(voiceAgentText(profile.provider == .openAI ? "OpenAI model ID" : "vLLM HTTPS address"),
                  text: profile.provider == .openAI ? $profile.model : $profile.address)
        #if !os(macOS)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
        #endif
        HStack {
          SecureField(voiceAgentText(savedToken ? "Access token stored in Keychain" : "Access token"), text: $token)
          Button { importsCertificate = false; importing = true } label: { Image(systemName: "square.and.arrow.down") }
            .buttonStyle(.bordered)
            .help(voiceAgentText("Import token file"))
            .accessibilityLabel(voiceAgentText("Import token file"))
          if savedToken || !token.isEmpty {
            Button { token = ""; removeToken = true } label: { Image(systemName: "trash") }
              .buttonStyle(.bordered)
              .help(voiceAgentText("Remove token"))
              .accessibilityLabel(voiceAgentText("Remove token"))
          }
        }
        if profile.provider == .vllm {
          HStack {
            Button(voiceAgentText("Import server certificate"), systemImage: "checkmark.shield") {
              importsCertificate = true; importing = true
            }
            .disabled(profile.origin == nil)
            if !profile.trustedCertificate.isEmpty {
              Button { profile.certificate = Data(); profile.certificateOrigin = nil } label: { Image(systemName: "trash") }
                .buttonStyle(.bordered)
                .help(voiceAgentText("Use system trust"))
                .accessibilityLabel(voiceAgentText("Use system trust"))
            }
          }
          if !profile.trustedCertificate.isEmpty {
            Text("SHA-256: " + SHA256.hash(data: profile.trustedCertificate).map { String(format: "%02X", $0) }.joined())
              .font(.caption.monospaced()).textSelection(.enabled)
          }
        }
        Toggle(voiceAgentText(profile.provider == .openAI ? "Share render images with OpenAI" : "Share render images"),
               isOn: $profile.sharesImages)
        if profile.provider == .openAI {
          Text(voiceAgentText("OpenAI receives your request and relevant visualization state. Render images are sent only if you enable sharing below."))
            .font(.caption).foregroundStyle(.secondary)
        }
        if test != nil { ProgressView().controlSize(.small) }
        if let model = testedModel { Label(model, systemImage: "checkmark.circle").foregroundStyle(.green) }
        if let errorText { Text(errorText).foregroundStyle(.red).textSelection(.enabled) }
      }
      .formStyle(.grouped)
      .disabled(test != nil || importing)
      .navigationTitle(voiceAgentText(isNew ? "Add model profile" : "Edit model profile"))
      .safeAreaInset(edge: .bottom) {
        HStack {
          Button(voiceAgentText("Cancel")) { test?.cancel(); dismiss() }
            .keyboardShortcut(.cancelAction)
          Spacer()
          Button(voiceAgentText("Test connection"), action: testConnection)
            .disabled(test != nil || !profile.isConfigured || (tokenOverride?.isEmpty ?? !savedToken))
          Button(voiceAgentText("OK")) { save() }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(test != nil || !profile.isConfigured)
        }
        .buttonStyle(.bordered)
        .padding()
        .background(.bar)
      }
    }
    #if os(macOS)
    .frame(minWidth: 460, idealWidth: 520, minHeight: 440, idealHeight: 510)
    #endif
    .onDisappear { test?.cancel() }
    .onChange(of: profile.provider) { _, _ in
      token = ""; removeToken = false; profile.sharesImages = false
      profile.certificate = Data(); profile.certificateOrigin = nil
      clearTest()
    }
    .onChange(of: profile.address) { _, _ in token = ""; clearTest() }
    .onChange(of: profile.model) { _, _ in clearTest() }
    .onChange(of: token) { _, _ in clearTest() }
    .onChange(of: removeToken) { _, _ in clearTest() }
    .onChange(of: profile.certificate) { _, _ in clearTest() }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
      do {
        guard let url = try result.get().first else { return }
        let data = try Self.readFile(url, limit: 64 * 1024)
        if importsCertificate {
          profile.certificate = try VoiceAgentTLS.certificateData(data)
          profile.certificateOrigin = profile.origin
        } else {
          guard let raw = String(data: data, encoding: .utf8) else { throw VoiceAgentError.configuration }
          let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
          try VoiceAgentEndpoint.validateToken(value)
          token = value
          removeToken = false
        }
        clearTest()
      } catch { errorText = error.localizedDescription }
    }
  }

  private func clearTest() { testedModel = nil; errorText = nil }

  private func save() {
    do { try settings.saveProfile(profile, token: tokenOverride); dismiss() }
    catch { errorText = error.localizedDescription }
  }

  private func testConnection() {
    clearTest()
    do {
      let client = try settings.modelClient(for: profile, tokenOverride: tokenOverride)
      test = Task { @MainActor in
        defer { test = nil }
        do { testedModel = try await client.testConnection() }
        catch is CancellationError { }
        catch { errorText = error.localizedDescription }
      }
    } catch { errorText = error.localizedDescription }
  }

  static func readFile(_ url: URL, limit: Int) throws -> Data {
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    let data = try file.read(upToCount: limit + 1) ?? Data()
    guard data.count <= limit else { throw VoiceAgentError.configuration }
    return data
  }
}
