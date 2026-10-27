import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Keeps the original picker URLs and their sandbox grants alive for an import.
final class VolumeImportSourceAccess: @unchecked Sendable {
  let url: URL
  private let accessedURLs: [URL]

  init(url: URL, selectedURLs: [URL]) {
    self.url = url
    accessedURLs = selectedURLs.filter { $0.startAccessingSecurityScopedResource() }
  }

  deinit {
    for url in accessedURLs { url.stopAccessingSecurityScopedResource() }
  }
}

// MARK: - FilePickerView

/**
 A SwiftUI wrapper for `UIDocumentPickerViewController` to allow file picking in SwiftUI.

 Presents an open-in-place picker for volume files or a DICOM directory.
 All selected file URLs are retained so detached raw data stays accessible too.
 */
struct FilePickerView: UIViewControllerRepresentable {
  enum Mode: String, Identifiable {
    case files
    case dicomDirectory
    case dicomReference
    case dicomRegistered

    var id: String { rawValue }
    var selectsDirectory: Bool { self != .files }
  }

  let mode: Mode
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
    picker.allowsMultipleSelection = mode == .files
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
        if parent.mode.selectsDirectory { return true }
        let ext = $0.pathExtension.lowercased()
        return VolumeFileParserFactory.supportedExtensions.contains(ext) || ext == "data"
      }) {
        parent.onSourcePicked(VolumeImportSourceAccess(url: url, selectedURLs: urls))
      } else {
        parent.onSourcePicked(nil)
      }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
      parent.onSourcePicked(nil)
    }
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
