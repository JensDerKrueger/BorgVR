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
  /// The shared application model used to manage application state.
  @Environment(RuntimeAppModel.self) private var runtimeAppModel
  /// The application settings injected from the environment.
  @EnvironmentObject var storedAppModel: StoredAppModel

  // MARK: - UI State Properties

  /// The path to the input file selected by the user.
  @State private var inputFile: String = ""
  @State private var inputAccess: VolumeImportSourceAccess?
  @State private var registeredInputAccess: VolumeImportSourceAccess?
  @State private var dicomResamplingFilter: BorgVRVolumeResamplingFilter = .trilinear
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
    case dicomFusion
  }
  /// The current mode of operation, determined by the selected file type.
  @State private var mode: Mode = .unknown

  /// The GUI logger instance used to log information, warnings, and errors.
  private var logger = GUILogger()

  // MARK: - View Body

  var body: some View {
    VStack(spacing: 16) {
      // Title
      Text("converter_title")
        .font(.largeTitle)
        .bold()

      // Subtitle
      Text("converter_subtitle")
        .font(.title2)
        .bold()

      // Instructions
      Text("Select a volume file or a DICOM folder. For QVIS and NHDR, select both the metadata and referenced raw data files.")
        .font(.body)
        .multilineTextAlignment(.leading)
        .padding()

      // File selection row
      HStack {

        Button {
          filePickerMode = .files
        } label: {
          Label("converter_select_input_volume", systemImage: "cube")
        }
        .disabled(isWorking)

        Button {
          filePickerMode = .dicomDirectory
        } label: {
          Label("Select DICOM folder", systemImage: "folder")
        }
        .disabled(isWorking)

        Button {
          if mode != .dicomFusion {
            if mode != .dicom {
              inputAccess = nil
              inputFile = ""
            }
            registeredInputAccess = nil
            mode = .dicomFusion
          }
          filePickerMode = inputAccess == nil ? .dicomReference : .dicomRegistered
        } label: {
          Label("DICOM Fusion", systemImage: "square.3.layers.3d")
        }
        .disabled(isWorking)

        if mode != .dicomFusion {
          Text(inputFile)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      .sheet(item: $filePickerMode) { pickerMode in
        FilePickerView(mode: pickerMode) { access in
          if let access {
            let url = access.url
            switch pickerMode {
              case .dicomRegistered:
                registeredInputAccess = access
                mode = .dicomFusion
              case .dicomReference:
                inputAccess = access
                inputFile = url.path
                mode = .dicomFusion
              case .dicomDirectory, .files:
                inputAccess = access
                inputFile = url.path
                registeredInputAccess = nil
                if pickerMode == .dicomDirectory {
                  mode = .dicom
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

      if mode == .dicomFusion {
        HStack(alignment: .top, spacing: 24) {
          dicomDirectoryRow("Reference series", access: inputAccess, pickerMode: .dicomReference)
          dicomDirectoryRow("Series to register", access: registeredInputAccess, pickerMode: .dicomRegistered)
        }
        .disabled(isWorking)
        Picker("Resampling", selection: $dicomResamplingFilter) {
          Text("Trilinear").tag(BorgVRVolumeResamplingFilter.trilinear)
          Text("Nearest Neighbor").tag(BorgVRVolumeResamplingFilter.nearestNeighbor)
        }
        .disabled(isWorking)
      }

      // Conversion / Copy controls
      if mode != .unknown {
        HStack {
          if mode == .convert || mode == .dicom || mode == .dicomFusion {
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
          runtimeAppModel.navigationState = .start
        } label: {
          Label("converter_back_to_main_menu", systemImage: "chevron.backward")
        }
        .font(.headline)
        .padding()
        .disabled(isWorking)
      }
    }
    .padding()
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

  private var canStartImport: Bool {
    mode != .unknown && inputAccess != nil && (mode != .dicomFusion || registeredInputAccess != nil)
  }

  private func dicomDirectoryRow(_ title: LocalizedStringKey, access: VolumeImportSourceAccess?,
                                 pickerMode: FilePickerView.Mode) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Button { filePickerMode = pickerMode } label: { Label(title, systemImage: "folder") }
      Text(access?.url.lastPathComponent ?? String(localized: "No directory selected"))
        .font(.caption)
        .lineLimit(1)
        .truncationMode(.middle)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Copy Native BorgVR

  /**
   Copies the selected BorgVR native dataset file to the app's private documents directory.

   Uses a helper function `copyFile` and logs progress and errors via `GUILogger`.
   */
  func copyData() {
    guard let inputAccess else { return }
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
      _ = copyFile(from: fileURL, toDir: documentsDirectory, logger: logger)
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
    guard canStartImport, let inputAccess else {
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
    let registeredInputAccess = mode == .dicomFusion ? self.registeredInputAccess : nil
    let source: BorgVRVolumeConversionSource
    let baseFilename: String
    if let registeredInputAccess {
      source = .registeredDICOMPair(reference: inputURL, moving: registeredInputAccess.url,
                                    filter: dicomResamplingFilter)
      baseFilename = inputURL.lastPathComponent + "-fused"
    } else {
      source = mode == .dicom ? .dicomDirectory(inputURL) : .file(inputURL)
      baseFilename = mode == .dicom ? inputURL.lastPathComponent : inputURL.deletingPathExtension().lastPathComponent
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
          self.registeredInputAccess = nil
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
              extensionStrategy: borderMode
            )
          ),
          logger: logger,
          cancellationToken: cancellationToken
        )
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
