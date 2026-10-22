import AppKit
import SwiftUI

struct MacKeyboardShortcut {
  let key: KeyEquivalent
  let modifiers: EventModifiers
  let displayName: String

  init(_ key: Character, modifiers: EventModifiers = [], displayName: String) {
    self.key = KeyEquivalent(key)
    self.modifiers = modifiers
    self.displayName = displayName
  }

  static let openDataset = MacKeyboardShortcut("o", modifiers: .command, displayName: "⌘O")
  static let importExport = MacKeyboardShortcut("o", modifiers: [.command, .shift], displayName: "⇧⌘O")
  static let saveDatasetState = MacKeyboardShortcut("s", modifiers: .command, displayName: "⌘S")
  static let restoreDatasetState = MacKeyboardShortcut("r", modifiers: .command, displayName: "⌘R")
  static let datasetInfo = MacKeyboardShortcut("i", modifiers: .command, displayName: "⌘I")
  static let closeDataset = MacKeyboardShortcut("w", modifiers: [.command, .shift], displayName: "⇧⌘W")
  static let startRecording = MacKeyboardShortcut("r", modifiers: [.command, .option], displayName: "⌥⌘R")
  static let stopRecording = MacKeyboardShortcut("s", modifiers: [.command, .option], displayName: "⌥⌘S")
  static let runScript = MacKeyboardShortcut("r", modifiers: [.command, .shift], displayName: "⇧⌘R")
  static let stopScript = MacKeyboardShortcut(".", modifiers: .command, displayName: "⌘.")
  static let startSharePlay = MacKeyboardShortcut("p", modifiers: [.command, .shift], displayName: "⇧⌘P")
  static let synchronizeView = MacKeyboardShortcut("v", modifiers: [.command, .option], displayName: "⌥⌘V")
  static let copyWebGPULink = MacKeyboardShortcut("c", modifiers: [.command, .option], displayName: "⌥⌘C")

  static func help(_ title: String, shortcut: MacKeyboardShortcut) -> String {
    "\(String(localized: String.LocalizationValue(title))) (\(shortcut.displayName))"
  }
}

enum MacRenderShortcut: String {
  case model = "1"
  case clipping = "2"
  case transferInteraction = "3"
  case drawing = "4"
  case placement = "5"
  case measurement = "6"
  case transferFunctionRendering = "7"
  case lightingRendering = "8"
  case isoRendering = "9"
  case screenshot = "s"
  case extractIsosurface = "x"
  case reset = "r"
  case bricks = "b"
  case synchronizeView = "v"
  case editor = "e"
  case lighting = "l"
  case objects = "o"
  case measurements = "m"
  case performance = "p"
  case log = "g"
  case datasetInfo = "i"
  case docking = "d"
  case toggleControls = "tab"

  var displayName: String {
    self == .toggleControls ? "Tab" : rawValue.uppercased()
  }

  static func help(_ title: String, shortcut: MacRenderShortcut) -> String {
    "\(String(localized: String.LocalizationValue(title))) (\(shortcut.displayName))"
  }

  init?(event: NSEvent) {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
    guard modifiers.intersection(disallowedModifiers).isEmpty else { return nil }

    if event.keyCode == 48 {
      self = .toggleControls
      return
    }
    guard let key = event.charactersIgnoringModifiers?.lowercased() else { return nil }
    self.init(rawValue: key)
  }
}

extension View {
  func macKeyboardShortcut(_ shortcut: MacKeyboardShortcut) -> some View {
    keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
  }
}
