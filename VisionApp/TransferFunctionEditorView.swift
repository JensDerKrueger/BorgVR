import SwiftUI
import UniformTypeIdentifiers

// MARK: - TransferFunctionEditorView

/**
 A SwiftUI view for editing a 1D transfer function used in volume rendering.

 This view displays:
 - A canvas showing the transfer function’s checkerboard, ribbon, grid, and curves.
 - Gesture handling to apply smooth-step edits to selected channels.
 - Toggles for selecting which channels (R, G, B, Opacity) are editable.
 - Load/Save controls for transfer function files.
 - Automatic loading/saving based on user settings.

 The view updates the shared `RenderingParamaters` and `AppModel` state accordingly.
 */
struct TransferFunctionEditorView: View {
  /// The shared application model, which holds the current interaction mode.
  @Environment(RuntimeAppModel.self) private var runtimeAppModel
  /// The shared rendering parameters, including the transfer function to edit.
  @Environment(SharedAppModel.self) private var sharedAppModel
  /// Application settings for auto-load/save behavior.
  @EnvironmentObject var storedAppModel: StoredAppModel

  /// Tracks the size of the drawing canvas for gesture translations.
  @State private var canvasSize: CGSize = .zero
  /// Whether the file picker sheet for loading transfer functions is presented.
  @State private var showLoadFilePicker = false

  /// Whether the Save As dialog is presented.
  @State private var showSaveDialog = false
  /// The filename entered in the Save As dialog (without extension).
  @State private var saveFilename = ""
  /// An error encountered during save operations.
  @State private var saveError: Error? = nil
  /// Whether to show an alert for a save error.
  @State private var showSaveError = false
  /// An error encountered during load operations.
  @State private var importError: Error? = nil
  /// Whether to show an alert for a load error.
  @State private var showImportError = false

  @State private var showICloudImporter = false
  @State private var showICloudExporter = false

  // MARK: - Gesture Handler

  /**
   Applies a drag gesture translation to the transfer function.

   Transforms the drag translation into normalized delta values,
   then applies `smoothStep` editing to the selected color/opacity channels.
   */
  private func applyDrag(_ value: DragGesture.Value) {
    // Normalize translation by canvas dimensions
    let dx = value.translation.width  / max(canvasSize.width,  1)
    let dy = value.translation.height / max(canvasSize.height, 1)
    let translationTF = SIMD3<Float>(Float(dx), Float(dy), 0)

    // Determine which channels are currently enabled for editing
    var channels: [Int] = []
    if runtimeAppModel.transferEditState.red     { channels.append(0) }
    if runtimeAppModel.transferEditState.green   { channels.append(1) }
    if runtimeAppModel.transferEditState.blue    { channels.append(2) }
    if runtimeAppModel.transferEditState.opacity { channels.append(3) }

    // Apply smooth-step to the transfer function data
    sharedAppModel.transferFunction
      .smoothStep(start: translationTF.x, shift: translationTF.y, channels: channels)

    sharedAppModel.synchronize(kind: .full)
  }

  // MARK: - View Body

  var body: some View {
    VStack(spacing: 20) {
      // Title
      Text("Transfer Function Editor")
        .font(.title)
        .bold()

      // Drawing canvas with transfer function preview
      ZStack {
        Canvas { context, size in
          // Update canvas size for gesture calculations
          DispatchQueue.main.async { self.canvasSize = size }

          // Draw ribbon and checkerboard background
          let ribbonHeight: CGFloat = 20
          let ribbonRect = CGRect(x: 0, y: 0, width: size.width, height: ribbonHeight)
          sharedAppModel.transferFunction.drawCheckerboard(in: context, rect: ribbonRect)
          sharedAppModel.transferFunction.drawRibbon(in: context, rect: ribbonRect)

          // Draw grid and curves below the ribbon
          let drawingRect = CGRect(x: 0, y: ribbonHeight, width: size.width, height: size.height - ribbonHeight - 5)
          sharedAppModel.transferFunction.drawGrid(in: context, rect: drawingRect)
          sharedAppModel.transferFunction.drawCurves(in: context, rect: drawingRect)
        }
        .frame(height: 400)
        .background(Color(.systemGray6))
        .border(Color.gray, width: 2)
        .id(sharedAppModel.transferFunction.data.hashValue) // Force redraw on data change

        // Transparent layer to capture drag gestures
        Color.clear
          .contentShape(Rectangle())
          .gesture(DragGesture().onChanged(applyDrag))
      }

      // MARK: - Channel and Storage Controls

      VStack(spacing: 20) {
        // Global toggle: enable all channels
        GroupBox(label: Label("Global", systemImage: "globe")) {
          Toggle("All", isOn: Binding(
            get: {
              runtimeAppModel.transferEditState.red &&
              runtimeAppModel.transferEditState.green &&
              runtimeAppModel.transferEditState.blue &&
              runtimeAppModel.transferEditState.opacity
            },
            set: { newValue in
              runtimeAppModel.transferEditState.red     = newValue
              runtimeAppModel.transferEditState.green   = newValue
              runtimeAppModel.transferEditState.blue    = newValue
              runtimeAppModel.transferEditState.opacity = newValue
            }
          ))
          .frame(width: 150)
        }

        // Color-only toggle and individual channel toggles
        GroupBox(label: Label("Color", systemImage: "paintpalette")) {
          Toggle("Only Color", isOn: Binding(
            get: {
              runtimeAppModel.transferEditState.red &&
              runtimeAppModel.transferEditState.green &&
              runtimeAppModel.transferEditState.blue &&
              !runtimeAppModel.transferEditState.opacity
            },
            set: { newValue in
              runtimeAppModel.transferEditState.red   = newValue
              runtimeAppModel.transferEditState.green = newValue
              runtimeAppModel.transferEditState.blue  = newValue
              if newValue { runtimeAppModel.transferEditState.opacity = false }
            }
          ))
          .frame(width: 150)

          HStack {
            Toggle("Red", isOn: Binding(
              get: {
                runtimeAppModel.transferEditState.red
              },
              set: {
                runtimeAppModel.transferEditState.red = $0
              }
            )).frame(width: 150)

            Toggle("Green", isOn: Binding(
              get: {
                runtimeAppModel.transferEditState.green
              },
              set: {
                runtimeAppModel.transferEditState.green = $0
              }
            )).frame(width: 150)

            Toggle("Blue", isOn: Binding(
              get: {
                runtimeAppModel.transferEditState.blue
              },
              set: {
                runtimeAppModel.transferEditState.blue = $0
              }
            )).frame(width: 150)
          }
        }

        // Opacity toggle
        GroupBox(label: Label("Opacity", systemImage: "circle.lefthalf.fill")) {
          Toggle("Opacity", isOn: Binding(
            get: {
              runtimeAppModel.transferEditState.opacity
            },
            set: {
              runtimeAppModel.transferEditState.opacity = $0
            }
          ))
          .frame(width: 150)
        }

        // Load/Save controls
        GroupBox(label: Label("Storage", systemImage: "folder")) {
          HStack {
            // Load button
            Button {
              showLoadFilePicker = true
            } label: {
              Label("Load", systemImage: "folder.fill")
            }
            .sheet(isPresented: $showLoadFilePicker) {
              FilePickerDialog(
                sharedAppModel: sharedAppModel,
                isPresented: $showLoadFilePicker
              )
            }

            // Save button
            Button {
              saveFilename = ""
              showSaveDialog = true
            } label: {
              Label("Save", systemImage: "square.and.arrow.down")
            }
            .sheet(isPresented: $showSaveDialog) {
              SaveAsDialog(isPresented: $showSaveDialog, filename: $saveFilename) { name in
                let url = FileManager.default
                  .urls(for: .documentDirectory, in: .userDomainMask).first!
                  .appendingPathComponent(name)
                  .appendingPathExtension("tf1d")
                do {
                  try sharedAppModel.transferFunction.save(to: url)
                } catch {
                  saveError       = error
                  showSaveError   = true
                }
              }
            }
            .alert("Save Failed", isPresented: $showSaveError, presenting: saveError) { _ in
              Button("OK", role: .cancel) {}
            } message: { error in
              Text(error.localizedDescription)
            }

            Spacer()

            // Auto-load/save toggle
            Text("Load and Save Automatically")
            Toggle("", isOn: $storedAppModel.autoloadTF)
              .labelsHidden()
          }
          HStack {
            Button {
              showICloudImporter = true
            } label: {
              Label("Import", systemImage: "square.and.arrow.down.on.square")
            }
            .alert("Import Failed", isPresented: $showImportError, presenting: importError) { _ in
              Button("OK", role: .cancel) {}
            } message: { error in
              Text(error.localizedDescription)
            }
            .fileImporter(
              isPresented: $showICloudImporter,
              allowedContentTypes: [.transferFunction],
              allowsMultipleSelection: false
            ) { result in
              switch result {
                case .success(let urls):
                  if let url = urls.first {
                    if url.startAccessingSecurityScopedResource() {
                      defer { url.stopAccessingSecurityScopedResource() }
                      do {
                        try sharedAppModel.transferFunction.load(from: url)
                        sharedAppModel.synchronize(kind: .full)
                      } catch {
                        importError = error
                        showImportError = true
                      }
                    }
                  }
                case .failure(let error):
                  importError = error
                  showImportError = true
              }
            }

            Button {
              showICloudExporter = true
            } label: {
              Label("Export", systemImage: "square.and.arrow.up.on.square")
            }
            .fileExporter(
              isPresented: $showICloudExporter,
              document: TransferFunctionDocument(transferFunction: sharedAppModel.transferFunction),
              contentType: .data,
              defaultFilename: "TransferFunction.tf1d"
            ) { result in
              if case .failure(let error) = result {
                saveError = error
                showSaveError = true
              }
            }
            Spacer()
          }
          .padding(.top)


        }
      }
    }
    .padding()

  }


}

// MARK: - FilePickerDialog

/**
 A SwiftUI view that lists `.tf1d` files in the app’s Documents directory for loading a transfer function.

 Presents a list of filenames; tapping one attempts to load it into the rendering parameters.
 */
struct FilePickerDialog: View {
  /// The rendering parameters containing the transfer function.
  var sharedAppModel: SharedAppModel
  /// Binding controlling presentation.
  @Binding var isPresented: Bool
  /// URLs of available `.tf1d` files.
  @State private var availableFiles: [URL] = []
  /// Error encountered during load.
  @State private var loadError: Error? = nil
  /// Whether to show load error alert.
  @State private var showLoadError = false

  var body: some View {
    NavigationView {
      List(availableFiles, id: \.self) { fileURL in
        Button(action: {
          do {
            try sharedAppModel.transferFunction.load(from: fileURL)
            sharedAppModel.synchronize(kind: .full)
            isPresented = false
          } catch {
            loadError     = error
            showLoadError = true
          }
        }) {
          Text(fileURL.lastPathComponent)
        }
      }
      .navigationTitle("Choose Transfer Function")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { isPresented = false }
        }
      }
    }
    .onAppear { refreshAvailableFiles() }
    .alert("Load Failed", isPresented: $showLoadError, presenting: loadError) { _ in
      Button("OK", role: .cancel) { showLoadError = false }
    } message: { error in
      Text(error.localizedDescription)
    }
  }

  /**
   Scans the Documents directory for `.tf1d` files and updates `availableFiles`.
   */
  func refreshAvailableFiles() {
    let fileManager = FileManager.default
    if let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
      availableFiles = (try? fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "tf1d" }) ?? []
    } else {
      availableFiles = []
    }
  }
}

// MARK: - SaveAsDialog

/**
 A SwiftUI form to enter a filename and confirm saving the transfer function.

 Provides Cancel and Save actions.
 */
struct SaveAsDialog: View {
  /// Binding controlling presentation.
  @Binding var isPresented: Bool
  /// Binding for the filename input (without extension).
  @Binding var filename: String
  /// Closure invoked when user confirms Save.
  let onSave: (String) -> Void

  var body: some View {
    NavigationView {
      Form {
        TextField("File name", text: $filename)
          .textInputAutocapitalization(.never)
          .disableAutocorrection(true)
      }
      .navigationTitle("Save Transfer Function")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { isPresented = false }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            isPresented = false
            onSave(filename)
          }
          .disabled(filename.isEmpty)
        }
      }
    }
  }
}


struct TransferFunctionDocument: FileDocument {
  static var readableContentTypes: [UTType] = [.transferFunction]

  let transferFunction: TransferFunction1D

  init(transferFunction: TransferFunction1D) {
    self.transferFunction = transferFunction
  }

  init(configuration: ReadConfiguration) throws {
    throw CocoaError(.featureUnsupported)
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    let tmpURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("tf1d")

    try transferFunction.save(to: tmpURL)
    let data = try Data(contentsOf: tmpURL)
    return .init(regularFileWithContents: data)
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
