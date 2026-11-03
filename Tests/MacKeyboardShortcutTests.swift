import AppKit
import SwiftUI

private struct ShortcutTestFailure: Error { let message: String }

@main
private enum MacKeyboardShortcutTests {
  static func main() throws {
    func check(_ condition: Bool, _ message: String) throws {
      if !condition { throw ShortcutTestFailure(message: message) }
    }
    func shortcut(_ characters: String, code: UInt16,
                  flags: NSEvent.ModifierFlags = []) -> MacRenderShortcut? {
      let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
        timestamp: 0, windowNumber: 0, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
      return MacRenderShortcut(event: event)
    }
    let modes: [MacRenderShortcut] = [.model, .clipping, .transferInteraction, .drawing,
                                     .placement, .measurement, .volumeEditing]
    let codes: [UInt16] = [18, 19, 20, 21, 23, 22, 26]
    for (index, mode) in modes.enumerated() {
      try check(shortcut(String(index + 1), code: codes[index]) == mode,
                "Number key no longer selects its interaction mode")
      try check(mode.modifiers.isEmpty, "Interaction mode requires a modifier")
    }
    let rendering: [MacRenderShortcut] = [.transferFunctionRendering, .lightingRendering, .isoRendering]
    // Shifted symbols differ between US and German keyboard layouts.
    for symbols in [["!", "@", "#"], ["!", "\"", "\u{a7}"]] {
      for (index, mode) in rendering.enumerated() {
        try check(shortcut(symbols[index], code: codes[index], flags: .shift) == mode,
                  "Shift+number did not select the rendering mode")
        try check(mode.keyEquivalent == KeyEquivalent(Character(String(index + 1))) && mode.modifiers == .shift,
                  "Menu and event shortcuts disagree")
        try check(mode.displayName == "\u{21e7}\(index + 1)", "Tooltip does not show Shift")
      }
    }
    for flag: NSEvent.ModifierFlags in [.command, .control, .option] {
      try check(shortcut("!", code: 18, flags: [flag, .shift]) == nil,
                "A modified system shortcut triggered a render action")
    }
    try check(shortcut("8", code: 28) == nil && shortcut("9", code: 25) == nil,
              "Old rendering shortcuts remain active")
    try check(shortcut("k", code: 40) == .erase && shortcut("u", code: 32) == .restore,
              "Erase/Restore shortcuts changed")
    try check(shortcut("\t", code: 48) == .toggleControls, "Tab shortcut changed")
    let panels: [(String, UInt16, MacRenderShortcut)] = [
      ("e", 14, .editor), ("l", 37, .lighting), ("o", 31, .objects),
      ("m", 46, .measurements), ("t", 17, .brush), ("p", 35, .performance), ("g", 5, .log)
    ]
    for (key, code, expected) in panels {
      try check(shortcut(key, code: code) == expected, "Missing panel shortcut for \(key)")
      try check(expected.keyEquivalent == KeyEquivalent(Character(key)) && expected.modifiers.isEmpty,
        "Panel menu and key handling disagree for \(key)")
      try check(MacRenderShortcut.help("Panel", shortcut: expected).hasSuffix("(\(key.uppercased()))"),
        "Panel tooltip is missing its shortcut")
    }
    let equivalents = MacRenderShortcut.allCases.map { "\($0.keyEquivalent.character):\($0.modifiers.rawValue)" }
    try check(Set(equivalents).count == equivalents.count, "Render shortcuts must not conflict")
    let arrows: [(UInt16, Int, MacRenderShortcut, KeyEquivalent)] = [
      (123, NSLeftArrowFunctionKey, .translateLeft, .leftArrow),
      (124, NSRightArrowFunctionKey, .translateRight, .rightArrow),
      (125, NSDownArrowFunctionKey, .translateDown, .downArrow),
      (126, NSUpArrowFunctionKey, .translateUp, .upArrow)
    ]
    for (code, character, expected, equivalent) in arrows {
      let characters = String(UnicodeScalar(UInt32(character))!)
      try check(shortcut(characters, code: code, flags: [.function, .numericPad]) == expected,
                "Arrow key did not translate in the expected direction")
      try check(expected.keyEquivalent == equivalent && expected.modifiers.isEmpty,
                "Arrow key equivalent is incorrect")
      for flag: NSEvent.ModifierFlags in [.command, .control, .option, .shift] {
        try check(shortcut(characters, code: code, flags: flag) == nil,
                  "Modified arrow key triggered translation")
      }
    }
    print("Mac keyboard shortcut tests passed")
  }
}
