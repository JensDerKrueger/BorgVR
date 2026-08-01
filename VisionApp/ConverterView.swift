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
  /// The text log displaying progress, errors, and status messages.
  @State private var logText: String = ""
  /// The progress description text shown during file operations.
  @State private var progressText: String = ""
  /// The numeric value representing the progress of file operations (0.0–1.0).
  @State private var progressValue: Double = 0.0
  /// A textual description for the dataset (used in conversion mode).
  @State private var datasetDescription: String = ""
  /// A flag indicating whether the file picker sheet should be shown.
  @State private var showFilePicker = false
  /// A flag indicating whether a file operation is currently in progress.
  @State private var isWorking: Bool = false

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
      Text("converter_instructions")
        .font(.body)
        .multilineTextAlignment(.leading)
        .padding()

      // File selection row
      HStack {

        Button {
          showFilePicker = true
        } label: {
          Label("converter_select_input_volume", systemImage: "cube")
        }
        .disabled(isWorking)

        Text(inputFile)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .sheet(isPresented: $showFilePicker) {
        FilePickerView { url in
          if let url = url {
            let fileExtension = url.pathExtension.lowercased()
            switch fileExtension {
              case "dat", "nrrd", "nhdr":
                self.mode = .convert
              case "data":
                self.mode = .copy
              default:
                self.mode = .unknown
            }
            self.inputFile = url.relativePath
          } else {
            self.mode = .unknown
            self.inputFile = ""
          }
          showFilePicker = false
        }
      }

      // Conversion / Copy controls
      if mode != .unknown {
        HStack {
          if mode == .convert {
            Text("converter_description_label")
            TextField("converter_dataset_description_placeholder", text: $datasetDescription)
              .textFieldStyle(RoundedBorderTextFieldStyle())
              .padding()
          }
          Button {
            logText = ""
            if mode == .copy {
              copyData()
            } else {
              startConversion(description: datasetDescription)
            }
          } label: {
            Text(mode == .copy ? "converter_copy_data" : "converter_start_conversion")
          }
        }
        .disabled(isWorking || inputFile.isEmpty)
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
          runtimeAppModel.currentState = .start
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

  // MARK: - Copy Native BorgVR

  /**
   Copies the selected BorgVR native dataset file to the app's private documents directory.

   Uses a helper function `copyFile` and logs progress and errors via `GUILogger`.
   */
  func copyData() {

    isWorking = true

    // Perform copy on background thread
    DispatchQueue.global(qos: .userInteractive).async {
      defer {
        DispatchQueue.main.async {
          isWorking = false
          inputFile = ""
        }
      }

      let fileURL = URL(fileURLWithPath: inputFile)
      guard fileURL.startAccessingSecurityScopedResource() else {
        logger.error(
          String(
            format: NSLocalizedString(
              "converter_no_permission_access_file",
              comment: "No permission to access file"
            ),
            fileURL.path
          )
        )
        return
      }
      defer { fileURL.stopAccessingSecurityScopedResource() }

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
    guard !inputFile.isEmpty else {
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
    let outputFilename = URL(fileURLWithPath: inputFile)
      .deletingPathExtension()
      .lastPathComponent + ".data"
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

    isWorking = true

    // Perform conversion on background thread
    DispatchQueue.global(qos: .userInteractive).async {
      let timer = HighResolutionTimer()
      timer.start()
      defer {
        DispatchQueue.main.async {
          isWorking = false
          inputFile = ""
        }
      }

      do {
        let datURL = URL(fileURLWithPath: inputFile)
        guard datURL.startAccessingSecurityScopedResource() else {
          throw FileError.noPermission(
            String(
              format: NSLocalizedString(
                "converter_no_permission_access_file",
                comment: "No permission to access file"
              ),
              datURL.path
            )
          )
        }
        defer { datURL.stopAccessingSecurityScopedResource() }

        let ext = datURL.pathExtension
        let parser: VolumeFileParser
        if ext == "dat" {
          parser = try QVISParser(filename: inputFile)
        } else {
          parser = try NRRDParser(filename: inputFile)
        }

        let rawURL = URL(fileURLWithPath: parser.absoluteFilename)
        guard rawURL.startAccessingSecurityScopedResource() else {
          throw FileError.noPermission(
            String(
              format: NSLocalizedString(
                "converter_no_permission_access_file",
                comment: "No permission to access file"
              ),
              rawURL.path
            )
          )
        }
        defer { rawURL.stopAccessingSecurityScopedResource() }

        let volume = try RawFileAccessor(
          filename: parser.absoluteFilename,
          size: parser.size,
          bytesPerComponent: parser.bytesPerComponent,
          componentCount: parser.components,
          aspect: parser.sliceThickness,
          offset: parser.offset,
          readOnly: true
        )

        let baseFilename = URL(fileURLWithPath: inputFile)
          .deletingPathExtension()
          .lastPathComponent

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

        let reorganizer = BrickedVolumeReorganizer(
          inputVolume: volume,
          brickSize: storedAppModel.brickSize,
          overlap: storedAppModel.brickOverlap,
          extensionStrategy: borderMode
        )
        try reorganizer.reorganize(
          to: outputFile,
          datasetDescription: actualDesc,
          metaDescription: metaDesc,
          useCompressor: storedAppModel.enableCompression,
          logger: logger
        )
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
