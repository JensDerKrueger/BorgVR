import AVFoundation

final class SpeechHelper {
  private let synthesizer = AVSpeechSynthesizer()

  func speak(_ text: String, language: String = "en-US") {
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: language)
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate
    synthesizer.speak(utterance)
  }

  func stop() {
    synthesizer.stopSpeaking(at: .immediate)
  }
}
