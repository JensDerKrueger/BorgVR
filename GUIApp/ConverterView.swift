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

  @State private var step: Int = 1

  @EnvironmentObject var storedAppModel: StoredAppModel

  /**
   The shared application model environment object that manages global state.
   */
  @Environment(RuntimeAppModel.self) private var runtimeAppModel

  // Create an instance of our GUI logger.
  // (It starts with no bindings until we set them in onAppear.)
  private var logger = GUILogger()

  var body: some View {
    VStack(spacing: 16) {
      // Title
      Text("Import Dataset")
        .font(.title)
        .bold()
        .frame(maxWidth: .infinity, alignment: .leading)

      // Step indicator
      Text("Step \(step) of 6")
        .font(.subheadline)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)

      // Wizard content by step
      Group {
        switch step {
          case 1:
            // Step 1: Input source
            VStack(alignment: .leading, spacing: 12) {
              Text("Select Input Source")
                .font(.headline)
              Text("Choose a file (QVIS/NRRD) or a directory with DICOM files.")
                .font(.subheadline)
                .foregroundColor(.gray)

              HStack {
                Button {
                  selectInputFile()
                } label: {
                  Label("Select Input File", systemImage: "doc")
                }
                Text(inputFile.isEmpty ? "No file selected" : inputFile)
                  .lineLimit(1)
                  .truncationMode(.middle)
                  .foregroundColor(inputFile.isEmpty ? .gray : .primary)
              }

              HStack {
                Button {
                  selectInputDirectory()
                } label: {
                  Label("Select Input Directory", systemImage: "folder")
                }
                Text(inputDirectory.isEmpty ? "No directory selected" : inputDirectory)
                  .lineLimit(1)
                  .truncationMode(.middle)
                  .foregroundColor(inputDirectory.isEmpty ? .gray : .primary)
              }
            }
          case 2:
            // Step 2: Output directory
            VStack(alignment: .leading, spacing: 12) {
              Text("Select Output Directory")
                .font(.headline)
              Text("Choose a folder where the converted dataset will be stored.")
                .font(.subheadline)
                .foregroundColor(.gray)

              HStack {
                Text("Data Directory:")
                TextField("Select output folder", text: $storedAppModel.dataDirectory)
                  .textFieldStyle(RoundedBorderTextFieldStyle())
                  .accentColor(.blue)
                Button {
                  showDirectoryPicker = true
                } label: {
                  Label("Browse", systemImage: "ellipsis.circle")
                }
              }
            }
          case 3:
            // Step 3: Output filename
            VStack(alignment: .leading, spacing: 12) {
              Text("Enter Output Filename")
                .font(.headline)
              Text("Provide a name for the new dataset file.")
                .font(.subheadline)
                .foregroundColor(.gray)

              HStack {
                Text("Output File:")
                TextField("Enter output file name", text: $outputFile)
                  .textFieldStyle(RoundedBorderTextFieldStyle())
                  .accentColor(.blue)
              }
            }
          case 4:
            // Step 4: Description
            VStack(alignment: .leading, spacing: 12) {
              Text("Enter Description (Optional)")
                .font(.headline)
              Text("Provide a description of the dataset.")
                .font(.subheadline)
                .foregroundColor(.gray)

              HStack {
                Text("Description:")
                TextField("Enter Description", text: $datasetDescription)
                  .textFieldStyle(RoundedBorderTextFieldStyle())
                  .accentColor(.blue)
              }
            }
          case 5:
            // Step 5: Confirm and start
            VStack(alignment: .leading, spacing: 12) {
              Text("Ready to Convert")
                .font(.headline)

              if storedAppModel.lastMinute {
                Text("Review settings and start the conversion process.")
                  .font(.subheadline)
                  .foregroundColor(.gray)
                HStack(spacing: 8) {
                  Text("Bricksize:")
                  TextField("Bricksize", text: $tempBrickSize, onCommit: validateBrickSize)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .accentColor(.blue)
                    .frame(maxWidth: 120)
                    .onAppear { tempBrickSize = String(storedAppModel.brickSize) }
                  if let error = brickSizeErrorMsg {
                    Text(error).foregroundColor(.red).font(.caption)
                  }
                }
              }
            }
          default:
            // Conversion running: show progress and log only
            VStack(alignment: .leading, spacing: 8) {
              Text("Converting…")
                .font(.headline)
              HStack {
                Text(progressText)
                ProgressView(value: progressValue)
                  .padding(.leading)
              }
              TextEditor(text: $logText)
                .border(Color.gray, width: 1)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 220)
            }

        }
      }

      Spacer()

      // Navigation controls
      if !isConverting {
        HStack {
          Button {
            if step > 1 { step -= 1 }
          } label: {
            Label("Back", systemImage: "chevron.backward")
          }
          .disabled(step == 1)

          Spacer()

          Button {
            // Validate minimal inputs for each step before advancing
            switch step {
              case 1:
                if !inputFile.isEmpty || !inputDirectory.isEmpty { step += 1 }
              case 2:
                if !storedAppModel.dataDirectory.isEmpty { step += 1 }
              case 3:
                if !outputFile.isEmpty { step += 1 }
              case 4:
                step += 1
              case 5:
                step += 1
                startConversion()
              default:
                runtimeAppModel.currentState = .start
            }
          } label: {
            Label(step < 5 ? "Next" : (step == 5 ? "Start Conversion" : "Close"), systemImage: step < 5 ? "chevron.forward" : "checkmark.circle")
          }
          .disabled(
            (step == 1 && (inputFile.isEmpty && inputDirectory.isEmpty)) ||
            (step == 2 && storedAppModel.dataDirectory.isEmpty) ||
            (step == 3 && outputFile.isEmpty) ||
            (step == 5 && brickSizeErrorMsg != nil) ||
            (step == 6 && isConverting)
          )
        }
      }

      // Footer
      HStack {
        Button {
          runtimeAppModel.currentState = .start
        } label: {
          Label("Back to main menu", systemImage: "chevron.backward.circle")
        }
        .disabled(isConverting)

        Spacer()
      }
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
            storedAppModel.dataDirectory = selectedURL.path
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
    if let size = Int(tempBrickSize), size >= 1 + storedAppModel.brickOverlap * 2 {
      storedAppModel.brickSize = size
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

        let bricksize = storedAppModel.brickSize

        let directoryURL = URL(fileURLWithPath: storedAppModel.dataDirectory)
        let outputFilePath = directoryURL.appendingPathComponent(outputFile).path

        let borderMode: ExtensionStrategy
        switch storedAppModel.borderModeString {
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
                                 overlap: storedAppModel.brickOverlap,
                                 outputFilename: appendExtensionIfNeeded(to:outputFilePath,ext:"data"),
                                 datasetDescription: datasetDescription == "" ? "Converted from QVIS Volume \(fileNameWithoutExtension)" : datasetDescription,
                                 useCompressor: storedAppModel.enableCompression,
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
                                 overlap: storedAppModel.brickOverlap,
                                 outputFilename:appendExtensionIfNeeded(to:outputFilePath,ext:"data"),
                                 datasetDescription: datasetDescription == "" ? "Converted from NRRD Volume \(fileNameWithoutExtension)" : datasetDescription,
                                 useCompressor: storedAppModel.enableCompression,
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
                               overlap: storedAppModel.brickOverlap,
                               outputFilename: appendExtensionIfNeeded(to:outputFilePath,ext:"data"),
                               datasetDescription: datasetDescription == "" ? "Converted from DICOM Stack \(dirName)" : datasetDescription,
                               useCompressor: storedAppModel.enableCompression,
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

