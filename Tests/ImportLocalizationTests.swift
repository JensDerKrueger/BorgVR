import Foundation

private struct Catalog: Decodable {
  struct Entry: Decodable {
    struct Translation: Decodable {
      struct Unit: Decodable { let state: String; let value: String }
      let stringUnit: Unit
    }
    let localizations: [String: Translation]
  }
  let sourceLanguage: String
  let strings: [String: Entry]
}

private func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw NSError(domain: message, code: 1) }
}

private let catalogURL = URL(fileURLWithPath: CommandLine.arguments[1])
private let catalog = try JSONDecoder().decode(Catalog.self,
  from: Data(contentsOf: catalogURL))
let resources = URL(fileURLWithPath: CommandLine.arguments[2])
let root = catalogURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let brickingSource = try String(contentsOf: root.appendingPathComponent(
  "BORGVR-IO/Importers/BrickedVolumeReorganizer.swift"), encoding: .utf8)
let brickingCalls = try NSRegularExpression(pattern: #"L\(\s*"[^"]+"\s*,\s*value:\s*"([^"]+)""#)
let brickingMessages = Set(brickingCalls.matches(in: brickingSource,
  range: NSRange(brickingSource.startIndex..., in: brickingSource)).map {
    String(brickingSource[Range($0.range(at: 1), in: brickingSource)!])
  })
try require(!brickingMessages.isEmpty, "Bricking localization coverage did not find any messages")
for message in brickingMessages {
  try require(catalog.strings[message] != nil, "Missing shared bricking translation: \(message)")
}
let formats = try NSRegularExpression(pattern: #"%(?:\.\d+)?(?:ll|l)?[@df%]"#)
func placeholders(_ text: String) -> [String] {
  formats.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
    let token = String(text[Range($0.range, in: text)!])
    return token == "%%" ? nil : token
  }
}
try require(catalog.sourceLanguage == "en", "Unexpected source language")
for language in ["de", "en", "es", "fr"] {
  guard let bundle = Bundle(path: resources.appendingPathComponent("\(language).lproj").path) else {
    fatalError("Missing compiled resources for \(language)")
  }
  for (key, entry) in catalog.strings {
    guard let unit = entry.localizations[language]?.stringUnit else {
      fatalError("Missing \(language) translation: \(key)")
    }
    try require(unit.state == "translated" && !unit.value.isEmpty, "Incomplete translation: \(key)")
    try require(placeholders(key) == placeholders(unit.value), "Format mismatch (\(language)): \(key)")
    if language == "en" { try require(unit.value == key, "English fallback changed: \(key)") }
    let translated = bundle.localizedString(forKey: key, value: "MISSING", table: "ImportMessages")
    try require(translated == unit.value, "Compiled translation not found (\(language)): \(key)")
    let arguments: [CVarArg] = placeholders(key).map {
      switch $0 {
        case "%@": "sample" as NSString
        case "%ld": 37
        case "%lld": Int64(37)
        case "%d": Int32(37)
        default: 0.75
      }
    }
    _ = String(format: translated, arguments: arguments)
  }
}
print("Import localization passed: \(catalog.strings.count) messages, four languages, compiled resources and format arguments")
