import SwiftUI
import UIKit

// Only parser discovery and explanation copy are stubbed; the picker and access grants are real.
enum VolumeFileParserFactory {
  static let supportedExtensions = ["nrrd", "nhdr", "dat"]
}

enum SupportingFileAccessExplanation {
  static func shouldShow() -> Bool { true }
  static func disable() {}
  static let title = "Supporting file"
  static let dismissPermanentlyTitle = "Don't explain again"
  static func message(for url: URL) -> String { url.lastPathComponent }
}

@MainActor
private final class TestDocumentPicker: UIDocumentPickerViewController {
  private(set) var dismissalCount = 0
  private var completion: (() -> Void)?

  override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
    dismissalCount += 1
    self.completion = completion
  }

  func finishDismissal() {
    let callback = completion
    completion = nil
    callback?()
  }
}

@main
@MainActor
struct FilePickerSimulatorTests {
  static func main() {
    let header = URL(fileURLWithPath: "/tmp/volume.nrrd")
    let raw = URL(fileURLWithPath: "/tmp/volume.raw")
    let directory = URL(fileURLWithPath: "/tmp/dicom", isDirectory: true)
    for mode in [FilePickerView.Mode.files, .dicomDirectory, .zarrDirectory, .imageSequence] {
      let url = mode.selectsDirectory ? directory : header
      check(mode: mode, urls: [url], expected: url)
      check(mode: mode, urls: nil, expected: nil)
    }
    check(mode: .files, urls: [raw, header], expected: header)
    check(mode: .files, urls: [raw], expected: nil)
    check(mode: .files, urls: [], expected: nil)
    check(mode: .files, supportingFile: raw, urls: [raw], expected: raw)
    print("File picker passed: files, DICOM/fusion directories, Zarr, images, cancellation, filtering, supporting files and exactly-once delivery after native dismissal")
  }

  private static func check(mode: FilePickerView.Mode, supportingFile: URL? = nil,
                            urls: [URL]?, expected: URL?) {
    var results: [URL?] = []
    let picker = FilePickerView(mode: mode, supportingFileURL: supportingFile) {
      results.append($0?.url)
    }
    let coordinator = picker.makeCoordinator()
    let controller = TestDocumentPicker(forOpeningContentTypes: [.item])
    if let urls { coordinator.documentPicker(controller, didPickDocumentsAt: urls) }
    else { coordinator.documentPickerWasCancelled(controller) }
    precondition(results.isEmpty, "Must not replace the source page while the native picker is closing")
    precondition(controller.dismissalCount == 1)
    controller.finishDismissal()
    precondition(results.count == 1 && results[0] == expected,
      "Must deliver the result without relying on SwiftUI sheet onDismiss")
    coordinator.documentPickerWasCancelled(controller)
    controller.finishDismissal()
    precondition(results.count == 1 && controller.dismissalCount == 1,
      "Duplicate native callbacks must not advance the wizard twice")
  }
}
