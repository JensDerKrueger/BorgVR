import Foundation
import Speech
import AVFoundation
import Combine

// What the service sends to your view
public enum VoiceMessage: Equatable {
  case transcript(text: String, isFinal: Bool)
  case stateChanged(VoiceCommandService.State)
}

@MainActor
public final class VoiceCommandService: ObservableObject {
  // MARK: State
  public enum State: Equatable {
    case idle
    case requestingAuth
    case ready
    case listening(passive:Bool)
    case denied(String)
    case failed(String)
  }

  public struct Configuration: Equatable {
    public var reportPartialResults: Bool = true
    public var preferOnDevice: Bool = true
    public var bufferSize: AVAudioFrameCount = 1024
    public var stopOnFinalResult: Bool = true
    public var duckOthers: Bool = true
    public init() {}
  }

  @Published public private(set) var state: State = .idle
  @Published public private(set) var lastTranscript: String = ""

  public var isEnabled: Bool {
    switch state {
      case .listening: return true
      default: return false
    }
  }

  public var isPassive: Bool {
    if case .listening(let passive) = state {
      return passive
    } else {
      return false
    }
  }

  func enterPassiveMode() {
    guard case .listening(let passive) = state, !passive else { return }
    self.state = .listening(passive: true)
  }

  func exitPassiveMode() {
    guard case .listening(let passive) = state, passive else { return }
    self.state = .listening(passive: false)
  }

  /// Set this from your view to receive messages.
  /// Called on the main actor.
  public var onMessage: ((VoiceMessage) -> Void)?

  // MARK: Speech / Audio
  private let recognizer: SFSpeechRecognizer?
  private let configuration: Configuration
  private let audioEngine = AVAudioEngine()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var cancellables = Set<AnyCancellable>()

  // MARK: Init
  public init(locale: Locale = .current, configuration: Configuration = .init()) {
    self.recognizer = SFSpeechRecognizer(locale: locale)
    self.configuration = configuration

    NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
      .sink { [weak self] note in self?.handleInterruption(note) }
      .store(in: &cancellables)
  }

  deinit {
    if audioEngine.isRunning { audioEngine.stop() }
    request?.endAudio()
    task?.cancel()
    request = nil
    task = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  // MARK: Public API
  public func requestAuthorization(autostart:Bool=false) {
    transition(to: .requestingAuth)
    SFSpeechRecognizer.requestAuthorization { [weak self] auth in
      Task { @MainActor in
        guard let self else { return }
        switch auth {
          case .authorized:
            do {
              try self.configureAudioSession()
              self.transition(to: .ready)

              if autostart {
                self.startListening()
                self.enterPassiveMode()
              }

            } catch {
              self.fail("Audio session error: \(error.localizedDescription)")
            }
          case .denied:
            self.transition(to: .denied("User denied speech recognition."))
          case .restricted:
            self.transition(to: .denied("Speech recognition restricted on this device."))
          case .notDetermined:
            self.transition(to: .denied("Speech authorization not determined."))
          @unknown default:
            self.transition(to: .denied("Unknown authorization state."))
        }
      }
    }
  }

  public func startListening() {
    guard case .ready = state else { return }
    guard let recognizer, recognizer.isAvailable else {
      fail("Speech recognizer unavailable.")
      return
    }

    do {
      let req = SFSpeechAudioBufferRecognitionRequest()
      req.shouldReportPartialResults = configuration.reportPartialResults
      if configuration.preferOnDevice {
        req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
      }

      let input = audioEngine.inputNode
      let format = input.outputFormat(forBus: 0)
      input.removeTap(onBus: 0)
      input.installTap(onBus: 0,
                       bufferSize: configuration.bufferSize,
                       format: format) { [weak self] buffer, _ in
        self?.request?.append(buffer)
      }

      audioEngine.prepare()
      try audioEngine.start()

      self.request = req
      transition(to: .listening(passive:false))

      self.task = recognizer.recognitionTask(with: req) { [weak self] result, error in
        guard let self else { return }

        if let result = result {
          let text = result.bestTranscription.formattedString

          if self.lastTranscript != text {
            self.send(.transcript(text: text, isFinal: result.isFinal))
            self.lastTranscript = text
          }

          if result.isFinal, self.configuration.stopOnFinalResult {
            self.stopListening()
          }
        }

        if error != nil {
          self.stopListening()
        }
      }

    } catch {
      fail("Start failed: \(error.localizedDescription)")
      stopListening()
    }
  }

  public func stopListening() {
    if audioEngine.isRunning { audioEngine.stop() }
    request?.endAudio()
    task?.cancel()
    request = nil
    task = nil

    switch state {
      case .failed, .denied: break
      default: transition(to: .ready)
    }
  }

  // MARK: Helpers
  private func configureAudioSession() throws {
    var options: AVAudioSession.CategoryOptions = []
    if configuration.duckOthers { options.insert(.duckOthers) }

    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.record, mode: .measurement, options: options)
    try session.setActive(true, options: .notifyOthersOnDeactivation)
  }

  private func handleInterruption(_ note: Notification) {
    guard
      let info = note.userInfo,
      let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: typeValue)
    else { return }

    if type == .began { stopListening() }
  }

  private func transition(to newState: State) {
    state = newState
    send(.stateChanged(newState))
  }

  private func send(_ msg: VoiceMessage) {
    onMessage?(msg)
  }

  private func fail(_ message: String) {
    transition(to: .failed(message))
  }
}
