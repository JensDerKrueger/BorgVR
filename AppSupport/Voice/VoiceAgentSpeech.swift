import Foundation
import Combine
import Speech
import AVFoundation

@MainActor
final class VoiceAgentSpeech: ObservableObject {
  @Published private(set) var isRecording = false
  @Published private(set) var transcript = ""
  var onFinal: ((String) -> Void)?
  var onFailure: ((Error) -> Void)?
  private let engine = AVAudioEngine()
  private let synthesizer = AVSpeechSynthesizer()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var recognition: SFSpeechRecognitionTask?
  private var recognizer: SFSpeechRecognizer?
  private var silence: Task<Void, Never>?
  private var finalDeadline: Task<Void, Never>?
  private var recordingDeadline: Task<Void, Never>?
  private var interruption: NSObjectProtocol?
  private var generation = UUID()
  private var hasTap = false
  private var delivered = false

  init() {
    #if !os(macOS)
    interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
      object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.cancel() }
    }
    #endif
  }

  deinit {
    if let interruption { NotificationCenter.default.removeObserver(interruption) }
    silence?.cancel()
    finalDeadline?.cancel()
    recordingDeadline?.cancel()
    recognition?.cancel()
    engine.stop()
  }

  func start(onDeviceOnly: Bool) async throws {
    cancel()
    synthesizer.stopSpeaking(at: .immediate)
    let id = generation
    let authorization = await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
    #if os(macOS)
    let microphone = await AVCaptureDevice.requestAccess(for: .audio)
    #else
    let microphone = await AVAudioApplication.requestRecordPermission()
    #endif
    guard id == generation else { throw CancellationError() }
    guard authorization == .authorized, microphone else { throw VoiceAgentError.permissions }
    let language = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en").language.languageCode
    let locales = SFSpeechRecognizer.supportedLocales().filter { $0.language.languageCode == language }
    let locale = locales.first { $0.region == Locale.current.region } ?? locales.sorted { $0.identifier < $1.identifier }.first
    guard let locale, let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable,
          !onDeviceOnly || recognizer.supportsOnDeviceRecognition else { throw VoiceAgentError.speechUnavailable }
    self.recognizer = recognizer
    #if !os(macOS)
    try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: [.duckOthers])
    try AVAudioSession.sharedInstance().setActive(true)
    #endif
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      deactivateAudio()
      throw VoiceAgentError.speechUnavailable
    }
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.requiresOnDeviceRecognition = onDeviceOnly
    self.request = request
    delivered = false
    transcript = ""
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
    hasTap = true
    do {
      engine.prepare()
      try engine.start()
    } catch {
      cancel()
      throw VoiceAgentError.speechUnavailable
    }
    isRecording = true
    recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
      let text = result?.bestTranscription.formattedString
      let final = result?.isFinal == true
      let failed = error != nil
      Task { @MainActor [weak self] in
        guard let self, self.generation == id, !self.delivered else { return }
        // Some local recognizers return an empty final result after endAudio().
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self.transcript = text }
        if final { self.deliver(); return }
        if failed {
          if !self.isRecording && !self.transcript.isEmpty { self.deliver(); return }
          self.cancel()
          self.onFailure?(VoiceAgentError.speechUnavailable)
          return
        }
        self.silence?.cancel()
        self.silence = Task { @MainActor [weak self] in
          do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
          self?.finish()
        }
      }
    }
    recordingDeadline = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(45)) } catch { return }
      self?.finish()
    }
  }

  func finish() {
    guard isRecording else { return }
    stopInput()
    request?.endAudio()
    finalDeadline = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
      self?.deliver()
    }
  }

  func cancel() {
    generation = UUID()
    delivered = true
    stopInput()
    finalDeadline?.cancel()
    request?.endAudio()
    recognition?.cancel()
    recognition = nil
    recognizer = nil
    request = nil
    synthesizer.stopSpeaking(at: .immediate)
  }

  func speak(_ text: String) {
    guard !isRecording, !text.isEmpty else { return }
    #if !os(macOS)
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
    #endif
    let utterance = AVSpeechUtterance(string: String(text.prefix(8192)))
    utterance.voice = AVSpeechSynthesisVoice(language: Bundle.main.preferredLocalizations.first ?? "en")
    synthesizer.speak(utterance)
  }

  func stopSpeaking() { synthesizer.stopSpeaking(at: .immediate) }

  private func deliver() {
    guard !delivered else { return }
    let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    cancel()
    if !text.isEmpty { onFinal?(text) }
  }

  private func stopInput() {
    silence?.cancel()
    recordingDeadline?.cancel()
    engine.stop()
    if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
    isRecording = false
    deactivateAudio()
  }

  private func deactivateAudio() {
    #if !os(macOS)
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    #endif
  }
}
