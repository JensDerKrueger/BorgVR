import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif


// MARK: - ContentView
struct ConverterView: View {
  // UI state properties.
  @State private var inputFile: String = ""
  @State private var inputDirectory: String = ""
  @State private var outputFile: String = ""
  @State private var datasetDescription: String = ""
  @State private var logText: String = ""
  @State private var progressText: String = ""
  @State private var progressValue: Double = 0.0

  @State private var isConverting: Bool = false
  @State private var showDirectoryPicker = false

  @State private var tempBrickSize: String = ""
  @State private var brickSizeErrorMsg: String?


  @EnvironmentObject var appSettings: AppSettings

  /**
   The shared application model environment object that manages global state.
   */
  @Environment(AppModel.self) private var appModel

  // Create an instance of our GUI logger.
  // (It starts with no bindings until we set them in onAppear.)
  private var logger = GUILogger()

  var body: some View {
    VStack(spacing: 16) {
      // Step 1: Select input file or directory
      VStack{
        Text("Step 1: Select Input")
          .font(.headline)
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity, alignment: .leading)
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text("Choose the QVIS or NRRD file you want to import.")
              .font(.subheadline)
              .foregroundColor(.gray)
              .multilineTextAlignment(.center)

            HStack {
              Button("Select Input File") {
                selectInputFile()
              }
              Text(inputFile.isEmpty ? "No file selected" : inputFile)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(inputFile.isEmpty ? .gray : .primary)
            }
          }

          Spacer()
          Text("or")
            .font(.headline)
            .multilineTextAlignment(.center)
          Spacer()


          VStack(alignment: .leading, spacing: 4) {
            Text("Choose the Directory containing DICOM files you want to import.")
              .font(.subheadline)
              .foregroundColor(.gray)
              .multilineTextAlignment(.center)

            HStack {
              Button("Select Input Directory") {
                selectInputDirectory()
              }
              Text(inputDirectory.isEmpty ? "No file selected" : inputDirectory)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(inputDirectory.isEmpty ? .gray : .primary)
            }
          }
        }
      }

      // Step 2: Select output directory
      VStack(alignment: .leading, spacing: 4) {
        Text("Step 2: Select Output Directory")
          .font(.headline)
          .frame(maxWidth: .infinity, alignment: .leading)
        Text("Choose a folder where the converted dataset will be stored.")
          .font(.subheadline)
          .foregroundColor(.gray)
          .frame(maxWidth: .infinity, alignment: .leading)

        HStack {
          Text("Data Directory:")
          TextField("Select output folder", text: $appSettings.dataDirectory)
            .textFieldStyle(RoundedBorderTextFieldStyle())
            .accentColor(.blue)
            .disabled(isConverting)
          Button("...") {
            showDirectoryPicker = true
          }
          .disabled(isConverting)
        }
      }

      // Step 3: Specify output filename
      VStack(alignment: .leading, spacing: 4) {
        Text("Step 3: Enter Output Filename")
          .font(.headline)
          .frame(maxWidth: .infinity, alignment: .leading)
        Text("Provide a name for the new dataset file.")
          .font(.subheadline)
          .foregroundColor(.gray)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accentColor(.blue)

        HStack {
          Text("Output File:")
          TextField("Enter output file name", text: $outputFile)
            .textFieldStyle(RoundedBorderTextFieldStyle())
            .accentColor(.blue)
        }
      }

      // Step 4: Specify output filename
      VStack(alignment: .leading, spacing: 4) {
        Text("Step 4: Enter Description (Optional)")
          .font(.headline)
          .frame(maxWidth: .infinity, alignment: .leading)
        Text("Provide a decription of the dataset.")
          .font(.subheadline)
          .foregroundColor(.gray)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accentColor(.blue)

        HStack {
          Text("Description:")
          TextField("Enter Description", text: $datasetDescription)
            .textFieldStyle(RoundedBorderTextFieldStyle())
            .accentColor(.blue)
        }
      }

      // Step 5: Start conversion
      VStack(spacing: 4) {

        Text("Step 5: Start Conversion")
          .font(.headline)
          .frame(maxWidth: .infinity, alignment: .leading)

        Text("Click the button below to start the conversion process.")
          .font(.subheadline)
          .foregroundColor(.gray)
          .frame(maxWidth: .infinity, alignment: .leading)

        HStack {
          Button("Start Conversion") {
            startConversion()
          }
          Spacer()
        }
        .disabled(isConverting)
      }

      // Progress view
      HStack {
        Text(progressText)
        ProgressView(value: progressValue)
          .padding()
      }

      // Multi-line log display
      TextEditor(text: $logText)
        .border(Color.gray, width: 1)
        .font(.system(.body, design: .monospaced))

      Spacer()

      HStack {
        Button("Back to main menu") {
          appModel.currentState = .start
        }

        if appSettings.lastMinute {
          Spacer()
          HStack {
            Text("Bricksize:")

            TextField(
              "Bricksize",
              text: $tempBrickSize,
              onCommit: validateBrickSize
            )
              .textFieldStyle(RoundedBorderTextFieldStyle())
              .accentColor(.blue)
              .onAppear { tempBrickSize = String(appSettings.brickSize) }
          }
          if let error = brickSizeErrorMsg {
            Text(error).foregroundColor(.red).font(.caption)
          }
          Spacer()
        }
      }


      .disabled(isConverting)

    }
    .padding()
    .onAppear {
      // Once the view appears, set the logger’s bindings.
      logger.setLogBinding($logText)
      logger.setProgressBinding($progressText, $progressValue)
      logger.setMinimumLogLevel(.dev)
    }
    .fileImporter(isPresented: $showDirectoryPicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
      switch result {
        case .success(let urls):
          if let selectedURL = urls.first {
            appSettings.dataDirectory = selectedURL.path
          }
        case .failure(let error):
          logger.error("Error selecting directory: \(error.localizedDescription)")
      }
    }
  }

  /// Presents an NSOpenPanel to allow file selection (macOS only).
  func selectInputFile() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowsOtherFileTypes = true
    if let qvisType = UTType(filenameExtension: "dat"),
       let nrrdType = UTType(filenameExtension: "nrrd"),
       let nhdrType = UTType(filenameExtension: "nhdr"){
      panel.allowedContentTypes = [qvisType, nrrdType, nhdrType]
    }
    if panel.runModal() == .OK, let url = panel.url {
      if url.startAccessingSecurityScopedResource() {
        defer { url.stopAccessingSecurityScopedResource() }
        inputFile = url.path
        inputDirectory = ""
        outputFile = URL(fileURLWithPath: inputFile)
          .deletingPathExtension().lastPathComponent
        datasetDescription = "Converted from \(outputFile)"
      } else {
        logger.error("Unable to access the selected file due to sandbox restrictions.")
      }
    }
  }

  private func validateBrickSize() {
    if let size = Int(tempBrickSize), size >= 1 + appSettings.brickOverlap * 2 {
      appSettings.brickSize = size
      brickSizeErrorMsg = nil
    } else {
      brickSizeErrorMsg = "Must be ≥ 1 + overlap × 2."
    }
  }

  func selectInputDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url {
      if url.startAccessingSecurityScopedResource() {
        defer { url.stopAccessingSecurityScopedResource() }
        inputDirectory = url.path
        inputFile = ""
        outputFile = URL(fileURLWithPath: inputDirectory).lastPathComponent
        datasetDescription = "Converted from DICOM Directory \(outputFile)"
      } else {
        logger.error("Unable to access the selected directory due to sandbox restrictions.")
      }
    }
  }

  func appendExtensionIfNeeded(to filename: String, ext: String) -> String {
    let extWithDot = ext.hasPrefix(".") ? ext : "." + ext
    if filename.lowercased().hasSuffix(extWithDot.lowercased()) {
      return filename
    } else {
      return filename + extWithDot
    }
  }

  /**
   Converts a raw volume file into the BorgVR file format.

   This function reads volume data from a raw file using a `RawFileAccessor` and then uses a `BrickedVolumeReorganizer`
   to partition the volume into bricks. The reorganized data is written to an output file.

   - Parameters:
   - inputFilename: The path to the raw input volume file.
   - size: A vector representing the dimensions (width, height, depth) of the volume.
   - maxBrickSize: The maximum brick size to use for partitioning the volume.
   - bytesPerVoxel: The number of bytes per voxel in the volume.
   - aspect: A vector representing the aspect ratio scaling for the volume.
   - overlap: The overlap between adjacent bricks.
   - outputFilename: The name of the output file to create.
   - description: A short description of the dataset.
   - Throws: An error if reading or reorganizing the volume fails.
   */
  func convertRawVolume(inputFilename: String,
                        offset: Int,
                        size: Vec3<Int>,
                        maxBrickSize: Int,
                        bytesPerVoxel: Int,
                        aspect: Vec3<Float>,
                        overlap: Int,
                        outputFilename: String,
                        datasetDescription: String,
                        useCompressor:Bool,
                        extensionStrategy:ExtensionStrategy) throws {
    let volume = try RawFileAccessor(
      filename: inputFilename,
      size: size,
      bytesPerComponent: bytesPerVoxel,
      componentCount: 1,
      aspect: aspect,
      offset: offset,
      readOnly: true
    )

    // Create a reorganizer to partition the volume into bricks.
    let reorganizer = BrickedVolumeReorganizer(
      inputVolume: volume,
      brickSize: maxBrickSize,
      overlap: overlap,
      extensionStrategy: .fillZeroes
    )
    try reorganizer
      .reorganize(
        to: outputFilename,
        datasetDescription: datasetDescription,
        useCompressor: useCompressor,
        logger: logger
      )
  }

  /// Starts the conversion process.
  /// In this demo, the conversion process is simulated with a loop.
  func startConversion() {
    guard (!inputFile.isEmpty || !inputDirectory.isEmpty), !outputFile.isEmpty else {
      logger.error("Input or output file not specified!")
      return
    }

    logger.info("Starting conversion...")
#if DEBUG
    logger.warning("Running in debug mode. The conversion may take a long time.")
#endif
    isConverting = true

    // Run the conversion on a background thread.
    DispatchQueue.global(qos:.userInteractive ).async {
      let timer = HighResolutionTimer()
      timer.start()

      do {

        let bricksize = appSettings.brickSize

        let directoryURL = URL(fileURLWithPath: appSettings.dataDirectory)
        let outputFilePath = directoryURL.appendingPathComponent(outputFile).path

        let borderMode: ExtensionStrategy
        switch appSettings.borderModeString {
          case "zeroes":
            borderMode = .fillZeroes
          case "border":
            borderMode = .clamp
          case "repeat":
            borderMode = .repeatValue
          default:
            borderMode = .fillZeroes
            logger.error("Unsupported border mode \(borderMode) falling back to zeroes")
        }

        if inputFile != "" {

          let ext = URL(fileURLWithPath: inputFile).pathExtension


          if ext == "dat" {
            let parser = try QVISParser(filename: inputFile)
            let fileNameWithoutExtension = URL(fileURLWithPath: inputFile).deletingPathExtension().lastPathComponent

            try convertRawVolume(inputFilename: parser.absoluteFilename,
                                 offset:0,
                                 size: parser.size,
                                 maxBrickSize: bricksize,
                                 bytesPerVoxel: parser.bytesPerComponent,
                                 aspect: parser.sliceThickness,
                                 overlap: appSettings.brickOverlap,
                                 outputFilename: appendExtensionIfNeeded(to:outputFilePath,ext:"data"),
                                 datasetDescription: datasetDescription == "" ? "Converted from QVIS Volume \(fileNameWithoutExtension)" : datasetDescription,
                                 useCompressor: appSettings.enableCompression,
                                 extensionStrategy: borderMode)
          } else {
            logger.info("Opening NRRD volume ...")

            let parser = try NRRDParser(filename: inputFile)

            let fileNameWithoutExtension = URL(fileURLWithPath: inputFile).deletingPathExtension().lastPathComponent

            logger.info("Converting NRRD volume to BorgVR file format ...")

            try convertRawVolume(inputFilename: parser.absoluteFilename,
                                 offset: parser.offset,
                                 size: parser.size,
                                 maxBrickSize: bricksize,
                                 bytesPerVoxel: parser.bytesPerComponent,
                                 aspect: parser.sliceThickness,
                                 overlap: appSettings.brickOverlap,
                                 outputFilename:appendExtensionIfNeeded(to:outputFilePath,ext:"data"),
                                 datasetDescription: datasetDescription == "" ? "Converted from NRRD Volume \(fileNameWithoutExtension)" : datasetDescription,
                                 useCompressor: appSettings.enableCompression,
                                 extensionStrategy: borderMode)

            if parser.dataIsTempCopy {
              try FileManager.default.removeItem(at: URL(fileURLWithPath: parser.absoluteFilename))
            }

          }

        } else {
          let directory = URL(fileURLWithPath: inputDirectory, isDirectory: true)

          let fileManager = FileManager.default
          let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
          let dicomFiles = files.filter { $0.isFileURL }

          logger.info("Scanning directory for DICOM files...")

          guard !dicomFiles.isEmpty else {
            logger.error("No files found in directory.")
            exit(1)
          }

          logger.info(String(format: "Found %d DICOM files.", dicomFiles.count))

          let dicomVolume = try DicomParser.decodeVolume(from: dicomFiles)

          let tempDir = FileManager.default.temporaryDirectory
          let uuid = UUID().uuidString
          let tempURL = tempDir.appendingPathComponent(uuid)

          logger.info("Converting DICOM stack to temporary raw file...")

          try dicomVolume.voxelData.withUnsafeBytes { try Data($0).write(to: tempURL) }

          let dirName = URL(fileURLWithPath: inputDirectory).lastPathComponent

          logger.info("Converting raw file to BorgVR file format...")
          try convertRawVolume(inputFilename: tempURL.path,
                               offset:0,
                               size: Vec3<Int>(x: dicomVolume.width,
                                               y: dicomVolume.height,
                                               z: dicomVolume.depth),
                               maxBrickSize: bricksize,
                               bytesPerVoxel: dicomVolume.bytesPerVoxel,
                               aspect: Vec3<Float>(x: dicomVolume.scale.x,
                                                   y: dicomVolume.scale.y,
                                                   z: dicomVolume.scale.z),
                               overlap: appSettings.brickOverlap,
                               outputFilename: appendExtensionIfNeeded(to:outputFilePath,ext:"data"),
                               datasetDescription: datasetDescription == "" ? "Converted from DICOM Stack \(dirName)" : datasetDescription,
                               useCompressor: appSettings.enableCompression,
                               extensionStrategy: borderMode)

          try FileManager.default.removeItem(at: tempURL)
        }
      } catch let error as QVISParser.Error {
        logger.error("QVISParser Error: \(error.localizedDescription)")
      } catch let error as NRRDParser.Error {
        logger.error("NRRDParser Error: \(error.localizedDescription)")
      } catch let error as RawFileAccessor.Error {
        logger.error("RawFileAccessor Error: \(error.localizedDescription)")
      } catch let error as MemoryMappedFile.Error {
        logger.error("MemoryMappedFile Error: \(error.localizedDescription)")
      } catch {
        logger.error("An unexpected error occurred: \(error.localizedDescription)")
      }
      DispatchQueue.main.async {
        isConverting = false
      }
      let total = timer.stop()
      logger.info("Time elapsed: \(total) seconds")
    }
  }
}
