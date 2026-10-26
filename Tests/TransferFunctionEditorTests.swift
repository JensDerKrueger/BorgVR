import AppKit
import Combine
import SwiftUI

// Isolate the real editor and TF drawing code from datasets, persistence and SharePlay.
struct BorgVRTransferFunctionSnapshot {
  let channel: Int
  let samples: [SIMD4<UInt8>]
  let revision: UInt64
}
struct TransferEditing {
  var red = false, green = false, blue = false, opacity = true
}
enum RenderMode { case transferFunction1D }
final class RenderingParameters: ObservableObject {
  let transferFunctions = (0..<4).map { channel in
    let tf = TransferFunction1D()
    tf.smoothStep(start: Float(channel) * 0.1, shift: 0.2, channels: [0, 1, 2, 3])
    return tf
  }
  @Published var componentCount = 4
  @Published var selectedTransferFunctionChannel = 0
  @Published var transferEditing = TransferEditing()
  @Published var renderMode = RenderMode.transferFunction1D
  var transferFunction: TransferFunction1D { transferFunctions[selectedTransferFunctionChannel] }
  func loadTransferFunction(from url: URL) throws { try transferFunction.load(from: url) }
}
struct EditorTestLogger {
  func info(_ text: String) {}
  func warning(_ text: String) {}
}
final class AppModel: ObservableObject {
  let logger = EditorTestLogger()
  func transferFunctionFileURL() -> URL? { nil }
}
final class SharePlayCoordinator: ObservableObject {
  enum Kind { case full, stateOnly }
  func synchronize(kind: Kind) {}
  func flushSynchronization() {}
}
struct TransferFunctionCatalogEntry: Identifiable {
  let id: String
  let displayName: String
  let url: URL
}
enum TransferFunctionCatalog {
  static let didChangeNotification = Notification.Name("EditorTestCatalogChanged")
  static func entries(additionalDirectoryURLs: [URL], datasetTransferFunctionURL: URL?,
                      logger: EditorTestLogger) -> [TransferFunctionCatalogEntry] { [] }
  static func store(transferFunction: TransferFunction1D, description: String,
                    logger: EditorTestLogger) throws -> URL { throw CocoaError(.featureUnsupported) }
}
extension View {
  func screenControlButtons() -> some View { self }
  func screenControlMenu() -> some View { self }
}

private struct EditorTestFailure: Error { let message: String }

@MainActor
private final class EditorTestDelegate: NSObject, NSApplicationDelegate {
  private var window: NSWindow!

  func applicationDidFinishLaunching(_ notification: Notification) {
    Task { @MainActor in
      do {
        try await runEditor(flexible: false)
        try await runEditor(flexible: true)
        print("macOS TF channel picker tests passed (docked and detached layouts)")
        NSApp.terminate(nil)
      } catch {
        FileHandle.standardError.write(Data("TF editor test failed: \(error)\n".utf8))
        exit(1)
      }
    }
  }

  private func runEditor(flexible: Bool) async throws {
    let parameters = RenderingParameters()
    let samples = parameters.transferFunctions.map(\.data)
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 360),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: TransferFunctionEditorView(usesFlexibleCanvasHeight: flexible)
      .environmentObject(parameters).environmentObject(AppModel()).environmentObject(SharePlayCoordinator()))
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    try await waitUntil { self.segmented(in: host) != nil }
    guard let control = segmented(in: host) else { throw EditorTestFailure(message: "Missing channel picker") }

    var inControlCallback = false
    var publishedInsideControl = false
    let observer = parameters.objectWillChange.sink {
      if inControlCallback { publishedInsideControl = true }
    }
    defer { observer.cancel() }
    for channel in [1, 2, 3, 0, 3, 1, 0, 2] {
      control.selectedSegment = channel
      inControlCallback = true
      control.sendAction(control.action, to: control.target)
      inControlCallback = false
      guard !publishedInsideControl else {
        throw EditorTestFailure(message: "Published inside SwiftUI's segmented-control update callback")
      }
      try await waitUntil { parameters.selectedTransferFunctionChannel == channel }
      guard parameters.transferFunction === parameters.transferFunctions[channel] else {
        throw EditorTestFailure(message: "Editor selected the wrong TF")
      }
    }
    parameters.selectedTransferFunctionChannel = 0
    try await waitUntil { control.selectedSegment == 0 }
    guard parameters.transferFunctions.map(\.data) == samples else {
      throw EditorTestFailure(message: "Channel selection modified TF samples")
    }
  }

  private func waitUntil(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !predicate() {
      guard ContinuousClock.now < deadline else { throw EditorTestFailure(message: "UI update timed out") }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func segmented(in view: NSView) -> NSSegmentedControl? {
    if let control = view as? NSSegmentedControl { return control }
    for child in view.subviews { if let control = segmented(in: child) { return control } }
    return nil
  }
}

@main
private enum TransferFunctionEditorTests {
  static func main() {
    let app = NSApplication.shared
    let delegate = EditorTestDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.prohibited)
    app.run()
  }
}
