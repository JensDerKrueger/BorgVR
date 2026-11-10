import SwiftUI
import RealityKit
import UniformTypeIdentifiers

// MARK: - FileError

/**
 An enumeration of custom file errors encountered during file operations.

 - fileNotFound: The specified file was not found.
 - noPermission: There is no permission to access the specified file.
 */
enum FileError: Error {
  /// Indicates that the specified file was not found.
  case fileNotFound(String)
  /// Indicates that there is no permission to access the specified file.
  case noPermission(String)
}

// MARK: - ConverterView

/**
 A view responsible for importing and converting datasets for BorgVR.

 This view allows users to select a pair of input files (metadata + volume data),
 displays progress and logging information during the import process, and initiates
 either a conversion or a copy operation depending on the selected file type.
 */
struct ConverterView: View {
  @State private var receivedAt = Date()
  @State private var sourceNote = ""
  @State private var imageSizeX = ""
  @State private var imageSizeY = ""
  @State private var imageSizeZ = ""
  @State private var selectedImportKind: VolumeImportKind?
  @State private var pendingImportKind: VolumeImportKind? = .volumeFile
  @State private var choosingImportKind = true
  /// The shared application model used to manage application state.
  @Environment(RuntimeAppModel.self) private var runtimeAppModel
  /// The application settings injected from the environment.
  @EnvironmentObject var storedAppModel: StoredAppModel

  // MARK: - UI State Properties

  /// The path to the input file selected by the user.
  @State private var inputFile: String = ""
  @State private var inputAccess: VolumeImportSourceAccess?
  @State private var fusionReference = VolumeFusionSelection()
  @State private var fusionRegistered = VolumeFusionSelection()
  @State private var filePickerMode: FilePickerView.Mode?
  /// The text log displaying progress, errors, and status messages.
  @State private var logText: String = ""
  /// The progress description text shown during file operations.
  @State private var progressText: String = ""
  /// The numeric value representing the progress of file operations (0.0–1.0).
  @State private var progressValue: Double = 0.0
  /// A textual description for the dataset (used in conversion mode).
  @State private var datasetDescription: String = ""
  /// A flag indicating whether a file operation is currently in progress.
  @State private var isWorking: Bool = false
  @State private var importedDatasetURL: URL?
  @State private var isOpening = false
  @State private var openErrorMessage: String?
  @State private var conversionCancellationToken: BorgVRVolumeConversionCancellationToken?
  @State private var conversionCancellationRequested = false

  @State private var isExporting = false
  @State private var exportURL: URL?

  // MARK: - Operation Mode

  /**
   Represents the mode of file operation.

   - unknown: The file type is not recognized.
   - copy: The file is a BorgVR native volume and will be copied without conversion.
   - convert: The file is a volume in a format that requires conversion.
   */
  enum Mode {
    case unknown
    case copy
    case convert
    case dicom
    case volumeFusion
    case imageSequence
  }
  /// The current mode of operation, determined by the selected file type.
  @State private var mode: Mode = .unknown

  /// The GUI logger instance used to log information, warnings, and errors.
  private var logger = GUILogger()

  // MARK: - View Body

  @ViewBuilder
  var body: some View {
    if choosingImportKind {
      ConverterWizardSelectionStep(
        title: "Import",
        question: "What would you like to import?",
        systemImage: pendingImportKind?.systemImage ?? "square.and.arrow.down",
        step: 1,
        total: 2,
        choices: importChoices,
        selectedID: pendingImportKind?.rawValue,
        canGoBack: !isWorking,
        onBack: goBack,
        onNext: commitImportKind
      )
      .padding()
    } else {
      importWorkflow
    }
  }

  private var importWorkflow: some View {
    VStack(spacing: 16) {
      ConverterWizardHeader(title: "Import", step: 2, total: 2)
      if let selectedImportKind {
        HStack {
          ConverterWizardStepIcon(systemImage: selectedImportKind.systemImage)
          Text(selectedImportKind.title).font(.headline)
          Spacer(minLength: 0)
        }
      }

      // Instructions
      if selectedImportKind == .volumeFile {
        VStack(alignment: .leading, spacing: 8) {
          ConverterVolumeFormatList(includesNativeBorgVR: true)
          Text("For QVIS and NHDR, select both the metadata and referenced raw data files.")
            .font(.caption)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
      } else if selectedImportKind == .dicomDirectory {
        Text("For a DICOM series, select the folder containing its slice files.")
          .foregroundStyle(.secondary)
      }

      // File selection row
      VStack(alignment: .leading, spacing: 12) {
        sourceButtons
          .disabled(isWorking)

        if selectedImportKind != .volumeFusion {
          Text(inputFile.isEmpty ? String(localized: "No file selected") : inputFile)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      .sheet(item: $filePickerMode) { pickerMode in
        FilePickerView(mode: pickerMode) { access in
          if let access {
            let url = access.url
            switch pickerMode {
              case .dicomDirectory, .zarrDirectory, .files, .imageSequence:
                inputAccess = access
                inputFile = url.path
                if pickerMode == .imageSequence {
                  mode = .imageSequence
                } else if pickerMode == .dicomDirectory {
                  mode = .dicom
                } else if pickerMode == .zarrDirectory {
                  mode = .convert
                } else {
                  switch url.pathExtension.lowercased() {
                    case "data":
                      self.mode = .copy
                    default:
                      self.mode = VolumeFileParserFactory.supportedExtensions.contains(url.pathExtension.lowercased()) ? .convert : .unknown
                  }
                }
            }
          }
          filePickerMode = nil
        }
      }

      // Conversion / Copy controls
      if mode == .imageSequence { imageSequenceSizeFields }

      if mode == .convert || mode == .dicom || mode == .volumeFusion || mode == .imageSequence {
        HStack(spacing: 24) {
          TextField("converter_source_note", text: $sourceNote)
            .textFieldStyle(.roundedBorder)
          DatePicker("converter_received_on", selection: $receivedAt, displayedComponents: [.date, .hourAndMinute])
            .datePickerStyle(.compact)
        }
        .disabled(isWorking)
      }
      if mode != .unknown {
        HStack {
          if mode == .convert || mode == .dicom || mode == .volumeFusion || mode == .imageSequence {
            Text("converter_description_label")
            TextField("converter_dataset_description_placeholder", text: $datasetDescription)
              .textFieldStyle(RoundedBorderTextFieldStyle())
              .padding()
          }
          if !isWorking {
            Button {
              logText = ""
              if mode == .copy {
                copyData()
              } else {
                startConversion(description: datasetDescription)
              }
            } label: {
              Text(
                mode == .copy
                  ? String(localized: "converter_copy_data")
                  : String(localized: "converter_start_conversion")
              )
            }
            .disabled(!canStartImport)
          }
        }
        .disabled(isWorking)
      }

      if !isWorking, let importedDatasetURL {
        Button {
          openImportedDataset(at: importedDatasetURL)
        } label: {
          Label("Open Dataset Now", systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)
        .disabled(isOpening)
      }

      // Progress indicators
      HStack {
        Text(progressText)
          .opacity(isWorking ? 1.0 : 0.0)
        ProgressView(value: progressValue)
          .progressViewStyle(LinearProgressViewStyle())
          .frame(width: 500)
          .padding()
          .opacity(isWorking ? 1.0 : 0.0)
        if isWorking {
          ProgressView()
            .progressViewStyle(CircularProgressViewStyle())
            .padding()
          if conversionCancellationToken != nil {
            Button(role: .cancel) {
              cancelConversion()
            } label: {
              Label("Cancel", systemImage: "xmark.circle")
            }
            .disabled(conversionCancellationRequested)
          }
        }
      }

      // Log output
      TextEditor(text: $logText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .border(Color.gray, width: 1)
        .font(.system(.body, design: .monospaced))
        .cornerRadius(8)
        .padding()

      HStack {

        Button {
          logText = ""
        } label: {
          Label("converter_clear_output", systemImage: "eraser")
        }
        .padding()

        Button {
          isExporting = true
        } label: {
          Label("converter_export_output", systemImage: "square.and.arrow.up")
        }
        .padding()

        Spacer()

        // Back button
        Button {
          goBack()
        } label: {
          Label("Back", systemImage: "chevron.backward")
        }
        .font(.headline)
        .padding()
        .disabled(isWorking)
      }
    }
    .padding()
    .disabled(isOpening)
    .alert("Dataset could not be opened", isPresented: Binding(
      get: { openErrorMessage != nil },
      set: { if !$0 { openErrorMessage = nil } }
    )) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(openErrorMessage ?? "")
    }
    .onAppear {
      // Set logger bindings when view appears
      logger.setLogBinding($logText)
      logger.setProgressBinding($progressText, $progressValue)
      logger.setMinimumLogLevel(.dev)
    }
    .fileExporter(
      isPresented: $isExporting,
      document: TextFileDocument(text: logText),
      contentType: .plainText,
      defaultFilename: NSLocalizedString(
        "converter_default_export_filename",
        comment: "Default filename for exported log"
      )
    ) { result in
      switch result {
        case .success(let url):
          logger.info(
            String(
              format: NSLocalizedString(
                "converter_log_saved_to_url",
                comment: "Log saved to URL"
              ),
              url.path
            )
          )
        case .failure(let error):
          logger.error(
            String(
              format: NSLocalizedString(
                "converter_failed_to_save_log",
                comment: "Failed to save log"
              ),
              error.localizedDescription
            )
          )
      }
    }
  }

  @ViewBuilder
  private var sourceButtons: some View {
    switch selectedImportKind {
      case .volumeFile:
        HStack {
          Button { filePickerMode = .files } label: {
            Label("converter_select_input_volume", systemImage: "cube")
          }
          Button { filePickerMode = .zarrDirectory } label: {
            Label("Select Zarr folder", systemImage: "folder")
          }
        }
      case .dicomDirectory:
        Button { filePickerMode = .dicomDirectory } label: {
          Label("Select DICOM folder", systemImage: "folder")
        }
      case .volumeFusion:
        HStack(alignment: .top, spacing: 24) {
          VolumeFusionSourcePicker(title: "Reference Volume", selection: $fusionReference)
          VolumeFusionSourcePicker(title: "Volume to Register", selection: $fusionRegistered)
        }
        .onChange(of: fusionReference.access?.url) { _, url in if url != nil { mode = .volumeFusion } }
        .onChange(of: fusionRegistered.access?.url) { _, url in if url != nil { mode = .volumeFusion } }
      case .imageSequence:
        Button { filePickerMode = .imageSequence } label: {
          Label("image_sequence_select", systemImage: "photo.on.rectangle.angled")
        }
      case .none:
        EmptyView()
    }
  }

  private var importChoices: [ConverterChoiceItem] {
    VolumeImportKind.allCases.map { kind in
      ConverterChoiceItem(id: kind.rawValue, title: kind.title, systemImage: kind.systemImage) {
        if !isWorking { pendingImportKind = kind }
      }
    }
  }

  private func commitImportKind() {
    guard !isWorking, let kind = pendingImportKind else { return }
    if selectedImportKind != kind {
      inputFile = ""
      inputAccess = nil
      fusionReference = VolumeFusionSelection()
      fusionRegistered = VolumeFusionSelection()
      filePickerMode = nil
      datasetDescription = ""
      sourceNote = ""
      receivedAt = Date()
      imageSizeX = ""
      imageSizeY = ""
      imageSizeZ = ""
      logText = ""
      progressText = ""
      progressValue = 0
      switch kind {
        case .volumeFile: mode = .unknown
        case .dicomDirectory: mode = .dicom
        case .volumeFusion: mode = .volumeFusion
        case .imageSequence: mode = .imageSequence
      }
    }
    selectedImportKind = kind
    choosingImportKind = false
  }

  private func goBack() {
    guard !isWorking else { return }
    if choosingImportKind {
      runtimeAppModel.navigationState = .start
    } else {
      choosingImportKind = true
    }
  }

  private var canStartImport: Bool {
    mode != .unknown && (mode == .volumeFusion
      ? fusionReference.input != nil && fusionRegistered.input != nil : inputAccess != nil)
      && (mode != .imageSequence || imageSequenceSize != nil)
  }

  private var imageSequenceSize: Vec3<Float>? {
    guard let x = Float(imageSizeX.replacingOccurrences(of: ",", with: ".")),
          let y = Float(imageSizeY.replacingOccurrences(of: ",", with: ".")),
          let z = Float(imageSizeZ.replacingOccurrences(of: ",", with: ".")),
          [x, y, z].allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
    return Vec3(x: x, y: y, z: z)
  }

  private var imageSequenceSizeFields: some View {
    VStack(alignment: .leading) {
      Text("image_sequence_size")
      HStack {
        Text("X"); TextField("m", text: $imageSizeX)
        Text("Y"); TextField("m", text: $imageSizeY)
        Text("Z"); TextField("m", text: $imageSizeZ)
      }
      .textFieldStyle(.roundedBorder)
    }
    .disabled(isWorking)
  }

  // MARK: - Copy Native BorgVR

  /**
   Copies the selected BorgVR native dataset file to the app's private documents directory.

   Uses a helper function `copyFile` and logs progress and errors via `GUILogger`.
   */
  @MainActor
  private func openImportedDataset(at url: URL) {
    guard !isOpening else { return }
    isOpening = true
    Task { @MainActor in
      defer { isOpening = false }
      do {
        let metadata = try BORGVRMetaData(url: url)
        try await runtimeAppModel.volumeBrush.prepareOpening(
          datasetID: metadata.uniqueID, datasetURL: url
        )
        runtimeAppModel.startImmersiveSpace(
          identifier: url.path, description: metadata.datasetDescription,
          source: .local, uniqueId: metadata.uniqueID, asGroupSessionHost: true
        )
      } catch is CancellationError {
        // The edit-selection dialog was cancelled; keep the import result available.
      } catch {
        openErrorMessage = error.localizedDescription
      }
    }
  }

  func copyData() {
    guard let inputAccess else { return }
    importedDatasetURL = nil
    isWorking = true

    // Perform copy on background thread
    DispatchQueue.global(qos: .userInteractive).async {
      defer { withExtendedLifetime(inputAccess) {} }
      defer {
        DispatchQueue.main.async {
          isWorking = false
          inputFile = ""
          self.inputAccess = nil
          mode = .unknown
        }
      }

      let fileURL = inputAccess.url

      let documentsDirectory = FileManager.default.urls(
        for: .documentDirectory,
        in: .userDomainMask
      ).first!

      logger.info(
        NSLocalizedString(
          "converter_copying_native_borgvr_file",
          comment: "Copying native BorgVR file"
        )
      )
      if let url = copyFile(from: fileURL, toDir: documentsDirectory, logger: logger) {
        DispatchQueue.main.async { importedDatasetURL = url }
      }
    }
  }

  // MARK: - Conversion

  /**
   Starts the conversion process for the selected dataset.

   Parses metadata, maps the raw volume file, and invokes `BrickedVolumeReorganizer`
   to create a bricked hierarchical format for BorgVR rendering.

   - Parameter description: A textual description for the dataset.
   */
  func startConversion(description: String) {
    importedDatasetURL = nil
    let provenance = sourceNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] :
      [BORGVRProvenanceEntry(sourceNote, date: receivedAt)]
    guard canStartImport,
          let inputAccess = mode == .volumeFusion ? fusionReference.access : self.inputAccess else {
      logger.error(
        NSLocalizedString(
          "converter_input_file_not_specified",
          comment: "Input file not specified error"
        )
      )
      return
    }

    let documentsDirectory = FileManager.default.urls(
      for: .documentDirectory,
      in: .userDomainMask
    ).first!
    let inputURL = inputAccess.url
    let imageExtent = mode == .imageSequence ? imageSequenceSize : nil
    let registeredInputAccess = mode == .volumeFusion ? fusionRegistered.access : nil
    let source: BorgVRVolumeConversionSource
    let baseFilename: String
    if registeredInputAccess != nil {
      source = .registeredPair(reference: fusionReference.input!, moving: fusionRegistered.input!,
                                    filter: storedAppModel.dicomResamplingFilter)
      baseFilename = inputURL.lastPathComponent + "-fused"
    } else {
      source = mode == .imageSequence ? .imageSequence(inputURL)
        : (mode == .dicom ? .dicomDirectory(inputURL) : .file(inputURL))
      baseFilename = mode == .dicom || mode == .imageSequence
        ? inputURL.lastPathComponent : inputURL.deletingPathExtension().lastPathComponent
    }
    let outputFilename = baseFilename + ".data"
    let outputFile = documentsDirectory.appendingPathComponent(outputFilename).relativePath

    logger.info(
      NSLocalizedString(
        "converter_starting_conversion",
        comment: "Starting conversion"
      )
    )
#if DEBUG
    logger.warning(
      NSLocalizedString(
        "converter_debug_mode_warning",
        comment: "Debug mode warning"
      )
    )
#endif

    let cancellationToken = BorgVRVolumeConversionCancellationToken()
    conversionCancellationToken = cancellationToken
    conversionCancellationRequested = false
    isWorking = true

    // Perform conversion on background thread
    DispatchQueue.global(qos: .userInteractive).async {
      defer { withExtendedLifetime((inputAccess, registeredInputAccess)) {} }
      let timer = HighResolutionTimer()
      timer.start()
      defer {
        DispatchQueue.main.async {
          conversionCancellationToken = nil
          conversionCancellationRequested = false
          isWorking = false
          inputFile = ""
          self.inputAccess = nil
          fusionReference = VolumeFusionSelection()
          fusionRegistered = VolumeFusionSelection()
          mode = .unknown
        }
      }

      do {
        let autoDescription = String(
          format: NSLocalizedString(
            "converter_dataset_description_auto",
            comment: "Auto-generated dataset description"
          ),
          baseFilename
        )

        let actualDesc = description.isEmpty ? autoDescription : description

        let metaDesc = String(
          format: NSLocalizedString(
            "converter_dataset_description_auto",
            comment: "Auto-generated metadata description"
          ),
          baseFilename
        )

        let borderMode: ExtensionStrategy
        switch storedAppModel.borderMode {
          case "zeroes":
            borderMode = .fillZeroes
          case "border":
            borderMode = .clamp
          case "repeat":
            borderMode = .repeatValue
          default:
            borderMode = .fillZeroes
            logger.error(
              String(
                format: NSLocalizedString(
                  "converter_unsupported_border_mode_fallback_zeroes",
                  comment: "Unsupported border mode fallback"
                ),
                storedAppModel.borderMode
              )
            )
        }

        try BorgVRVolumeConversionService.convert(
          BorgVRVolumeConversionRequest(
            source: source,
            destinationURL: URL(fileURLWithPath: outputFile),
            datasetDescription: actualDesc,
            metaDescription: metaDesc,
            settings: BorgVRVolumeConversionSettings(
              brickSize: storedAppModel.brickSize,
              overlap: storedAppModel.brickOverlap,
              useCompression: storedAppModel.enableCompression,
              extensionStrategy: borderMode,
              quantizeTo8Bit: storedAppModel.quantizeImportsTo8Bit, colorCompression: storedAppModel.importColorCompression
            ),
            physicalSizeMeters: imageExtent,
            provenance: provenance
          ),
          logger: logger,
          cancellationToken: cancellationToken
        )
        DispatchQueue.main.async { importedDatasetURL = URL(fileURLWithPath: outputFile) }
      }
      catch is CancellationError {
        logger.info(String(localized: "Conversion cancelled."))
      }
      catch let error as QVISParser.Error {
        logger.error(
          String(
            format: NSLocalizedString(
              "converter_qvisparser_error",
              comment: "QVISParser error"
            ),
            error.localizedDescription
          )
        )
      }
      catch let error as NRRDParser.Error {
        logger.error(
          String(
            format: NSLocalizedString(
              "converter_nrrdparser_error",
              comment: "NRRDParser error"
            ),
            error.localizedDescription
          )
        )
      }
      catch let error as RawFileAccessor.Error {
        logger.error(
          String(
            format: NSLocalizedString(
              "converter_rawfileaccessor_error",
              comment: "RawFileAccessor error"
            ),
            error.localizedDescription
          )
        )
      }
      catch let error as MemoryMappedFile.Error {
        logger.error(
          String(
            format: NSLocalizedString(
              "converter_memorymappedfile_error",
              comment: "MemoryMappedFile error"
            ),
            error.localizedDescription
          )
        )
      }
      catch let error as FileError {
        logger.error(
          String(
            format: NSLocalizedString(
              "converter_fileerror",
              comment: "FileError"
            ),
            error.localizedDescription
          )
        )
      }
      catch {
        logger.error(
          String(
            format: NSLocalizedString(
              "converter_unexpected_error",
              comment: "Unexpected error"
            ),
            error.localizedDescription
          )
        )
      }
      let total = timer.stop()
      logger.info(
        String(
          format: NSLocalizedString(
            "converter_time_elapsed_seconds",
            comment: "Time elapsed in seconds"
          ),
          total
        )
      )
    }
  }

  private func cancelConversion() {
    guard let conversionCancellationToken, !conversionCancellationRequested else { return }
    conversionCancellationRequested = true
    conversionCancellationToken.cancel()
  }
}

extension UTType {
  static var volumeData: UTType {
    UTType(exportedAs: "de.cgvis.volumedata")
  }
}

// MARK: - Preview

#Preview {
  ConverterView()
    .environment(RuntimeAppModel())
    .environmentObject(StoredAppModel())
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
