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
  @Environment(AppModel.self) private var appModel
  /// The application settings injected from the environment.
  @EnvironmentObject var appSettings: AppSettings

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
      Text("BorgVR Dataset Import")
        .font(.largeTitle)
        .bold()

      // Subtitle
      Text("Importing Volume Data")
        .font(.title2)
        .bold()

      // Instructions
      Text("""
            To begin the data import process, tap **Select Input Volume** and choose the volume to import:
            
            - **QVIS Volume**: Select a `.DAT` (metadata) file and its corresponding `.RAW` (volume data) file. This format **requires conversion**.
            - **NRRD Volume**: Select a `.NRRD` or a `.NHDR` (metadata) file and its corresponding volume data file. This format **requires conversion**.
            - **BorgVR Native Volume**: Select the `.DATA` volume file. This format is **copied without conversion**.
                        
            Due to restrictions in the **iOS App Sandbox security system**, you need to **manually select all files involved**. If you are importing a QVIS or NHDR volume you need to select both the **metadata file** and the **volume data file**. When copying a native BorgVR, just select the `.DATA` file.
            
            If you are importing a volume, enter a **description** for the dataset before proceeding. Then, tap **Start Conversion** to convert the data into a **bricked hierarchical format**, optimized for BorgVR rendering. If you are importing a BorgVR native volume, simply tap **Copy Dataset** to store the files in the app’s private space for high-performance visualization.
            """)
      .font(.body)
      .multilineTextAlignment(.leading)
      .padding()

      // File selection row
      HStack {
        Button("Select Input Volume") {
          showFilePicker = true
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
            Text("Description:")
            TextField("Enter a description for this dataset", text: $datasetDescription)
              .textFieldStyle(RoundedBorderTextFieldStyle())
              .padding()
          }
          Button(mode == .copy ? "Copy Data" : "Start Conversion") {
            logText = ""
            if mode == .copy {
              copyData()
            } else {
              startConversion(description: datasetDescription)
            }
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

        Button("Clear Output") {
          logText = ""
        }
        .padding()


        Button("Export Output") {
          isExporting = true
        }
        .padding()

        Spacer()

        // Back button
        Button("Back to Main Menu") {
          appModel.currentState = .start
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
      defaultFilename: "ImportOutput"
    ) { result in
      switch result {
        case .success(let url):
          logger.info("Log saved to \(url)")
        case .failure(let error):
          logger.error("Failed to save log: \(error.localizedDescription)")
      }
    }
  }

  // MARK: - Copy Native BorgVR

  /**
   Copies the selected BorgVR native dataset file to the app's private documents directory.

   Uses a helper function `copyFile` and logs progress and errors via `GUILogger`.
   */
  func copyData() {
    /**
     Copies a file from the given source URL to the specified destination directory.

     - Parameters:
     - sourceURL: The URL of the file to be copied.
     - destinationDirURL: The destination directory URL.
     - Returns: `true` if the file was copied successfully; otherwise, `false`.
     */
    func copyFile(from sourceURL: URL, toDir destinationDirURL: URL) -> Bool {
      let destinationURL = destinationDirURL.appendingPathComponent(sourceURL.lastPathComponent)
      let fileManager = FileManager.default
      do {
        let destinationDirectory = destinationURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: destinationDirectory.path) {
          try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        }
        if fileManager.fileExists(atPath: destinationURL.path) {
          try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        logger.info("File copied successfully")
        return true
      } catch {
        logger.error("Error copying file: \(error.localizedDescription)")
        return false
      }
    }

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
        logger.error("No Permission to access file \(fileURL)")
        return
      }
      defer { fileURL.stopAccessingSecurityScopedResource() }

      let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!

      logger.info("Copying Native BorgVR File")
      _ = copyFile(from: fileURL, toDir: documentsDirectory)
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
      logger.error("Input file not specified!")
      return
    }

    let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let outputFilename = URL(fileURLWithPath: inputFile)
      .deletingPathExtension()
      .lastPathComponent + ".data"
    let outputFile = documentsDirectory.appendingPathComponent(outputFilename).relativePath

    logger.info("Starting conversion...")
#if DEBUG
    logger.warning("Running in debug mode. The conversion may take a long time.")
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
          throw FileError.noPermission("No Permission to access file \(datURL)")
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
          throw FileError.noPermission("No Permission to access file \(rawURL)")
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

        let actualDesc = description.isEmpty
        ? "Converted from external volume file \(URL(fileURLWithPath: inputFile).deletingPathExtension().lastPathComponent)"
        : description

        let borderMode: ExtensionStrategy
        switch appSettings.borderMode {
          case "zeroes":
            borderMode = .fillZeroes
          case "border":
            borderMode = .clamp
          case "repeat":
            borderMode = .repeatValue
          default:
            borderMode = .fillZeroes
            logger.error("Unsupported border mode \(appSettings.borderMode), falling back to zeroes")
        }

        let reorganizer = BrickedVolumeReorganizer(
          inputVolume: volume,
          brickSize: appSettings.brickSize,
          overlap: appSettings.brickOverlap,
          extensionStrategy: borderMode
        )
        try reorganizer.reorganize(
          to: outputFile,
          datasetDescription: actualDesc,
          useCompressor: appSettings.enableCompression,
          logger: logger
        )
      }
      catch let error as QVISParser.Error {
        logger.error("QVISParser Error: \(error.localizedDescription)")
      }
      catch let error as NRRDParser.Error {
        logger.error("NRRDParser Error: \(error.localizedDescription)")
      }
      catch let error as RawFileAccessor.Error {
        logger.error("RawFileAccessor Error: \(error.localizedDescription)")
      }
      catch let error as MemoryMappedFile.Error {
        logger.error("MemoryMappedFile Error: \(error.localizedDescription)")
      }
      catch let error as FileError {
        logger.error("FileError: \(error.localizedDescription)")
      }
      catch {
        logger.error("An unexpected error occurred: \(error.localizedDescription)")
      }
      let total = timer.stop()
      logger.info("Time elapsed: \(total) seconds")
    }
  }
}

extension UTType {
  static var volumeData: UTType {
    UTType(exportedAs: "de.cgvis.volumedata")
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
