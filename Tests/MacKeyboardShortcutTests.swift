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
    print("Mac keyboard shortcut tests passed")
  }
}
