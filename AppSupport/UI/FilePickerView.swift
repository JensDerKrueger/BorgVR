import SwiftUI
import UniformTypeIdentifiers
import UIKit

// MARK: - FilePickerView

/**
 A SwiftUI wrapper for `UIDocumentPickerViewController` to allow file picking in SwiftUI.

 Presents an open-in-place picker for volume files or a DICOM directory.
 All selected file URLs are retained so detached raw data stays accessible too.
 */
struct FilePickerView: UIViewControllerRepresentable {
  enum Mode: String, Identifiable {
    case files
    case zarrDirectory
    case dicomDirectory
    case imageSequence

    var id: String { rawValue }
    var selectsDirectory: Bool { self != .files }
  }

  let mode: Mode
  var supportingFileURL: URL? = nil
  var onSourcePicked: (VolumeImportSourceAccess?) -> Void

  /**
   Creates the coordinator instance that acts as the `UIDocumentPickerViewControllerDelegate`.
   */
  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  /**
   Creates and configures a `UIDocumentPickerViewController`.

   - Parameter context: The SwiftUI context for coordination.
   - Returns: A configured `UIDocumentPickerViewController` allowing item selection.
   */
  func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
    let picker = UIDocumentPickerViewController(
      forOpeningContentTypes: mode.selectsDirectory ? [.folder] : [.item], asCopy: false
    )
    picker.delegate = context.coordinator
    picker.allowsMultipleSelection = mode == .files && supportingFileURL == nil
    if let supportingFileURL { picker.directoryURL = supportingFileURL.deletingLastPathComponent() }
    return picker
  }

  /**
   Updates the `UIDocumentPickerViewController` when SwiftUI state changes.

   This implementation does not require dynamic updates.
   */
  func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

  // MARK: - Coordinator

  /**
   A coordinator that bridges `UIDocumentPickerDelegate` callbacks into SwiftUI.

   Filters selected URLs for supported volume file extensions and calls the parent's closure.
   */
  class Coordinator: NSObject, UIDocumentPickerDelegate {
    /// Reference to the parent `FilePickerView`.
    private let parent: FilePickerView
    private var completed = false

    /**
     Initializes the coordinator with the parent view.

     - Parameter parent: The `FilePickerView` instance.
     */
    init(_ parent: FilePickerView) {
      self.parent = parent
    }

    /**
     Called when the user picks one or more documents.

     Filters the selected URLs for supported file extensions and passes the first match
     to the `onSourcePicked` closure; otherwise, passes `nil`.

     - Parameters:
     - controller: The document picker controller.
     - urls: The URLs of the selected documents.
     */
    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
      if let url = urls.first(where: {
        if parent.supportingFileURL != nil { return true }
        if parent.mode.selectsDirectory { return true }
        let ext = $0.pathExtension.lowercased()
        return VolumeFileParserFactory.supportedExtensions.contains(ext) || ext == "data"
      }) {
        finish(controller, access: VolumeImportSourceAccess(url: url, selectedURLs: urls))
      } else {
        finish(controller, access: nil)
      }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
      finish(controller, access: nil)
    }

    private func finish(_ controller: UIDocumentPickerViewController,
                        access: VolumeImportSourceAccess?) {
      guard !completed else { return }
      completed = true
      // UIKit can dismiss the document picker without SwiftUI's sheet onDismiss firing.
      // Deliver the result after dismissal so consumers can safely replace the source page.
      controller.dismiss(animated: true) {
        self.parent.onSourcePicked(access)
      }
    }
  }
}

struct SupportingFileAccessRequest: Identifiable {
  let id = UUID()
  let url: URL
}

struct SupportingFileAccessPicker: View {
  let request: SupportingFileAccessRequest
  let onSourcePicked: (VolumeImportSourceAccess?) -> Void
  @State private var showsExplanation = SupportingFileAccessExplanation.shouldShow()

  var body: some View {
    if showsExplanation {
      VStack(alignment: .leading, spacing: 24) {
        Text(SupportingFileAccessExplanation.title)
          .font(.title2.bold())
        Text(SupportingFileAccessExplanation.message(for: request.url))
          .fixedSize(horizontal: false, vertical: true)
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 16) { explanationButtons }
          VStack(alignment: .leading, spacing: 16) { explanationButtons }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
      }
      .padding(24)
      .frame(maxWidth: 640, alignment: .leading)
    } else {
      VStack(spacing: 12) {
        Text(String(format: String(localized: "Select the referenced file \"%@\" to continue importing.",
          table: "ImportMessages"), request.url.lastPathComponent))
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding()
        FilePickerView(mode: .files, supportingFileURL: request.url, onSourcePicked: onSourcePicked)
      }
    }
  }

  @ViewBuilder
  private var explanationButtons: some View {
    Button("Cancel", role: .cancel) { onSourcePicked(nil) }
    Button(SupportingFileAccessExplanation.dismissPermanentlyTitle) {
      SupportingFileAccessExplanation.disable()
      showsExplanation = false
    }
    Button("OK") { showsExplanation = false }
      .buttonStyle(.borderedProminent)
  }
}

/*
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of Duisburg-
 Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of this
 software and associated documentation files (the "Software"), to deal in the Software
 without restriction, including without limitation the rights to use, copy, modify,
 merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 permit persons to whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included in all copies
 or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
 CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR
 THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

struct PendingSystemFileExport: Identifiable {
  let id = UUID()
  let sourceURL: URL

  init(
    data: Data,
    defaultFilename: String,
    temporaryDirectoryName: String
  ) throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(temporaryDirectoryName, isDirectory: true)
      .appendingPathComponent(id.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
    sourceURL = directoryURL.appendingPathComponent(defaultFilename)
    try data.write(to: sourceURL, options: .atomic)
  }

  func removeTemporaryFiles() {
    try? FileManager.default.removeItem(at: sourceURL.deletingLastPathComponent())
  }
}

struct SystemFileExportPicker: UIViewControllerRepresentable {
  let sourceURL: URL
  let defaultDirectoryURL: URL?
  let completion: (URL?) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(completion: completion)
  }

  func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
    let picker = UIDocumentPickerViewController(
      forExporting: [sourceURL],
      asCopy: true
    )
    picker.directoryURL = defaultDirectoryURL
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(
    _ uiViewController: UIDocumentPickerViewController,
    context: Context
  ) {}

  final class Coordinator: NSObject, UIDocumentPickerDelegate {
    private let completion: (URL?) -> Void
    private var completed = false

    init(completion: @escaping (URL?) -> Void) {
      self.completion = completion
    }

    func documentPicker(
      _ controller: UIDocumentPickerViewController,
      didPickDocumentsAt urls: [URL]
    ) {
      finish(with: urls.first)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
      finish(with: nil)
    }

    private func finish(with url: URL?) {
      guard !completed else { return }
      completed = true
      completion(url)
    }
  }
}
