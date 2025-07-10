import SwiftUI
import UniformTypeIdentifiers
import UIKit

// MARK: - FilePickerView

/**
 A SwiftUI wrapper for `UIDocumentPickerViewController` to allow file picking in SwiftUI.

 Presents a document picker that allows the user to select files of any type. When the user selects one or more files,
 the coordinator filters them for supported volume file extensions (`.nrrd`, `.nhdr`, `.dat`, `.data`) and invokes
 the `onFilePicked` closure with the first matching URL or `nil` if none match.
 */
struct FilePickerView: UIViewControllerRepresentable {
  /// Closure invoked when the user selects a file. Passes the picked file URL or `nil`.
  var onFilePicked: (URL?) -> Void

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
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.item])
    picker.delegate = context.coordinator
    picker.allowsMultipleSelection = true
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
     to the `onFilePicked` closure; otherwise, passes `nil`.

     - Parameters:
     - controller: The document picker controller.
     - urls: The URLs of the selected documents.
     */
    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
      if let url = urls.first(where: {
        let ext = $0.pathExtension.lowercased()
        return ext == "nrrd" || ext == "nhdr" || ext == "dat" || ext == "data"
      }) {
        parent.onFilePicked(url)
      } else {
        parent.onFilePicked(nil)
      }
    }
  }
}

/*
 Copyright (c) 2025 Computer Graphics and Visualization Group, University of Duisburg-
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
