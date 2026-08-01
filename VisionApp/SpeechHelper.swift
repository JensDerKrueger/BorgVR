import AVFoundation

enum AppLanguage {
  /// Returns something like "en-US" or "de-DE".
  static var speechLocaleIdentifier: String {
    // "en", "de", "fr", ...
    let appLanguageCode = Bundle.main.preferredLocalizations.first ?? "en"

    if let regionCode = Locale.current.region?.identifier {
      // Combine app language with current region
      return "\(appLanguageCode)-\(regionCode)"
    } else {
      // Fallback: just the language
      return appLanguageCode
    }
  }
}

final class SpeechHelper : ObservableObject {
  private let synthesizer = AVSpeechSynthesizer()

  func speak(_ text: String) {
    let language = AppLanguage.speechLocaleIdentifier

    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: language)
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate
    synthesizer.speak(utterance)
  }

  func stop() {
    synthesizer.stopSpeaking(at: .immediate)
  }
}
