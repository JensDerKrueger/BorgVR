import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif


// MARK: - ContentView
struct ConverterView: View {
  private enum Operation: String, CaseIterable, Identifiable {
    case importDataset
    case exportDataset

    var id: Self { self }
  }

  // UI state properties.
  @State private var operation: Operation = .importDataset
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

  @State private var exportInputFile: String = ""
  @State private var exportOutputFile: String = ""
  @State private var exportInputURL: URL?
  @State private var exportOutputURL: URL?
  @State private var exportLevel = 0
  @State private var exportLevelDescriptions: [String] = []
  @State private var exportStep = 1
  @State private var exportDidFinish = false
  @State private var exportDidSucceed = false
  @State private var exportInputError: String?

  @EnvironmentObject var storedAppModel: StoredAppModel

  @StateObject private var dicomPreviewModel = DicomSlicePreviewModel()


  /**
   The shared application model environment object that manages global state.
   */
  @Environment(RuntimeAppModel.self) private var runtimeAppModel

  // Create an instance of our GUI logger.
  // (It starts with no bindings until we set them in onAppear.)
  private var logger = GUILogger()

  var body: some View {
    VStack(spacing: 16) {
      Picker("converter_mode", selection: $operation) {
        Text("converter_mode_import").tag(Operation.importDataset)
        Text("converter_mode_export").tag(Operation.exportDataset)
      }
      .pickerStyle(.segmented)
      .frame(maxWidth: 360)
      .disabled(isConverting)

      if operation == .importDataset {
      VStack(spacing: 16) {
      VStack {
        HStack {
          Text("converter_import_title")
            .font(.title)
            .bold()
            .padding()

          Text(
            String(
              format: NSLocalizedString("converter_step_of_total_format", comment: ""),
              step,
              6
            )
          )
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding()
        }
      }
      Spacer()

      HStack(alignment: .top) {
        VStack {
          wizardStepIcon(importStepSystemImage)
          Spacer()
        }

        Group {
          switch step {
            case 1:
              // Step 1: Input source
              VStack(alignment: .leading, spacing: 12) {
                Text("converter_step1_title")
                  .font(.headline)
                Text("converter_step1_subtitle")
                  .font(.subheadline)
                  .foregroundStyle(.secondary)

                if inputDirectory.isEmpty == false {
                  DicomSlicePreview(model: dicomPreviewModel)
                    .frame(height: 420)
                    .padding()
                }

                HStack {
                  Button {
                    selectInputFile()
                  } label: {
                    Label("converter_button_select_input_file", systemImage: "doc")
                  }
                  Text(inputFile.isEmpty ? NSLocalizedString("converter_status_no_file", comment: "") : inputFile)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(inputFile.isEmpty ? .secondary : .primary)
                }

                HStack {
                  Button {
                    selectInputDirectory()
                  } label: {
                    Label("converter_button_select_input_dir", systemImage: "folder")
                  }
                  Text(inputDirectory.isEmpty ? NSLocalizedString("converter_status_no_directory", comment: "") : inputDirectory)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(inputDirectory.isEmpty ? .secondary : .primary)
                }
              }
            case 2:
              // Step 2: Output directory
              VStack(alignment: .leading, spacing: 12) {
                Text("converter_step2_title")
                  .font(.headline)
                Text("converter_step2_subtitle")
                  .font(.subheadline)
                  .foregroundStyle(.secondary)

                HStack {
                  Text("converter_label_data_directory")
                  TextField("converter_textfield_output_folder_placeholder", text: $storedAppModel.dataDirectory)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                  Button {
                    showDirectoryPicker = true
                  } label: {
                    Label("converter_button_browse", systemImage: "ellipsis.circle")
                  }
                }
              }
            case 3:
              // Step 3: Output filename
              VStack(alignment: .leading, spacing: 12) {
                Text("converter_step3_title")
                  .font(.headline)
                Text("converter_step3_subtitle")
                  .font(.subheadline)
                  .foregroundStyle(.secondary)

                HStack {
                  Text("converter_label_output_file")
                  TextField("converter_textfield_output_filename_placeholder", text: $outputFile)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                }
              }
            case 4:
              // Step 4: Description
              VStack(alignment: .leading, spacing: 12) {
                Text("converter_step4_title")
                  .font(.headline)
                Text("converter_step4_subtitle")
                  .font(.subheadline)
                  .foregroundStyle(.secondary)

                HStack {
                  Text("converter_label_description")
                  TextField("converter_textfield_description_placeholder", text: $datasetDescription)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                }
              }
            case 5:
              // Step 5: Confirm and start
              VStack(alignment: .leading, spacing: 12) {
                Text("converter_step5_title")
                  .font(.headline)

                if storedAppModel.lastMinute {
                  Text("converter_step5_subtitle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                  HStack(spacing: 8) {
                    Text("converter_label_bricksize")
                    TextField(
                      "converter_textfield_bricksize_placeholder",
                      text: $tempBrickSize,
                      onCommit: validateBrickSize
                    )
                    .textFieldStyle(RoundedBorderTextFieldStyle())
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
                Text("converter_converting_title")
                  .font(.headline)
                HStack {
                  Text(progressText)
                  ProgressView(value: progressValue)
                    .padding(.leading)
                }
                TextEditor(text: $logText)
                  .border(Color.secondary.opacity(0.5), width: 1)
                  .font(.system(.body, design: .monospaced))
                  .frame(minHeight: 220)
              }
          }
          Spacer()
        }
      }

      Spacer()

      // Navigation controls
      if !isConverting {

        HStack {

          Button {
            runtimeAppModel.currentState = .start
          } label: {
            Label("converter_back_to_main_menu", systemImage: "chevron.backward.circle")
          }
          .disabled(isConverting)

          Spacer()

          Button {
            if step > 1 { step -= 1 }
          } label: {
            Label("converter_button_back", systemImage: "chevron.backward")
          }
          .disabled(step == 1)

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
            Label(
              step < 5
              ? "converter_nav_next"
              : (step == 5 ? "converter_nav_start" : "converter_nav_close"),
              systemImage: step < 5 ? "chevron.forward" : "checkmark.circle"
            )
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
      }
      } else {
        exportContent
      }
    }
    .padding()
    .onAppear {
      // Once the view appears, set the logger’s bindings.
      logger.setLogBinding($logText)
      logger.setProgressBinding($progressText, $progressValue)
      logger.setMinimumLogLevel(.dev)
    }
    .fileImporter(
      isPresented: $showDirectoryPicker,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: false
    ) { result in
      switch result {
        case .success(let urls):
          if let selectedURL = urls.first {
            storedAppModel.dataDirectory = selectedURL.path
          }
        case .failure(let error):
          logger.error(
            String(
              format: L(
                "converter_log_error_select_directory",
                comment: "Log: error while selecting directory"
              ),
              error.localizedDescription
            )
          )
      }
    }
  }

  private var exportContent: some View {
    VStack(spacing: 16) {
      HStack {
        Text("converter_export_title")
          .font(.title)
          .bold()
          .padding()

        Text(
          String(
            format: NSLocalizedString("converter_step_of_total_format", comment: ""),
            exportStep,
            4
          )
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
      }

      Spacer()

      HStack(alignment: .top) {
        VStack {
          wizardStepIcon(exportStepSystemImage)
          Spacer()
        }

        Group {
          switch exportStep {
            case 1:
              VStack(alignment: .leading, spacing: 12) {
                Text("converter_export_select_input")
                  .font(.headline)
                Text("converter_export_step1_subtitle")
                  .font(.subheadline)
                  .foregroundStyle(.secondary)

                Button {
                  selectExportInputFile()
                } label: {
                  Label("converter_export_select_input", systemImage: "shippingbox")
                }
                Text(
                  exportInputFile.isEmpty
                  ? NSLocalizedString("converter_status_no_file", comment: "")
                  : exportInputFile
                )
                .lineLimit(2)
                .truncationMode(.middle)
                .foregroundStyle(exportInputFile.isEmpty ? .secondary : .primary)

                if let exportInputError {
                  Label(exportInputError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                }
              }

            case 2:
              VStack(alignment: .leading, spacing: 12) {
                Text("converter_export_lod")
                  .font(.headline)
                Text("converter_export_step2_subtitle")
                  .font(.subheadline)
                  .foregroundStyle(.secondary)

                Picker("converter_export_lod", selection: $exportLevel) {
                  ForEach(exportLevelDescriptions.indices, id: \.self) { level in
                    Text(String(format: NSLocalizedString("converter_export_lod_option", comment: ""), level))
                      .tag(level)
                  }
                }
                .frame(maxWidth: 240)

                if exportLevelDescriptions.indices.contains(exportLevel) {
                  Text(exportLevelDescriptions[exportLevel])
                    .foregroundStyle(.secondary)
                }
              }

            case 3:
              VStack(alignment: .leading, spacing: 12) {
                Text("converter_export_select_output")
                  .font(.headline)
                Text("converter_export_step3_subtitle")
                  .font(.subheadline)
                  .foregroundStyle(.secondary)

                Button {
                  selectExportOutputFile()
                } label: {
                  Label("converter_export_select_output", systemImage: "doc.badge.arrow.up")
                }
                Text(
                  exportOutputFile.isEmpty
                  ? NSLocalizedString("converter_export_no_output", comment: "")
                  : exportOutputFile
                )
                .lineLimit(2)
                .truncationMode(.middle)
                .foregroundStyle(exportOutputFile.isEmpty ? .secondary : .primary)
              }

            default:
              VStack(alignment: .leading, spacing: 12) {
                Text(exportResultTitle)
                  .font(.headline)
                Text(exportResultSubtitle)
                  .font(.subheadline)
                  .foregroundStyle(.secondary)

                if isConverting {
                  HStack {
                    Text(progressText)
                    ProgressView(value: progressValue)
                      .padding(.leading)
                  }
                }

                TextEditor(text: $logText)
                  .border(Color.secondary.opacity(0.5), width: 1)
                  .font(.system(.body, design: .monospaced))
                  .frame(minHeight: 220)
              }
          }
          Spacer()
        }
      }

      Spacer()

      if !isConverting {
        HStack {
          Button {
            runtimeAppModel.currentState = .start
          } label: {
            Label("converter_back_to_main_menu", systemImage: "chevron.backward.circle")
          }

          Spacer()

          if exportStep > 1 && !exportDidSucceed {
            Button {
              exportStep -= 1
              exportDidFinish = false
            } label: {
              Label("converter_button_back", systemImage: "chevron.backward")
            }
          }

          if exportStep < 3 {
            Button {
              exportStep += 1
            } label: {
              Label("converter_nav_next", systemImage: "chevron.forward")
            }
            .disabled(
              (exportStep == 1 && exportLevelDescriptions.isEmpty) ||
              (exportStep == 2 && !exportLevelDescriptions.indices.contains(exportLevel))
            )
          } else if exportStep == 3 {
            Button {
              exportStep = 4
              startExport()
            } label: {
              Label("converter_export_start", systemImage: "square.and.arrow.up")
            }
            .disabled(exportOutputFile.isEmpty)
          } else if exportDidSucceed {
            Button {
              runtimeAppModel.currentState = .start
            } label: {
              Label("converter_nav_close", systemImage: "checkmark.circle")
            }
          }
        }
      }
    }
  }

  private var exportStepSystemImage: String {
    switch exportStep {
      case 1: return "shippingbox"
      case 2: return "square.3.layers.3d"
      case 3: return "doc.badge.arrow.up"
      default:
        if !exportDidFinish { return "arrow.up.doc" }
        return exportDidSucceed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }
  }

  private var exportResultTitle: LocalizedStringKey {
    if !exportDidFinish { return "converter_export_progress_title" }
    return exportDidSucceed ? "converter_export_completed_title" : "converter_export_failed_title"
  }

  private var exportResultSubtitle: LocalizedStringKey {
    if !exportDidFinish { return "converter_export_progress_subtitle" }
    return exportDidSucceed
      ? "converter_export_completed_subtitle"
      : "converter_export_failed_subtitle"
  }

  private var importStepSystemImage: String {
    switch step {
      case 1: return "tray.and.arrow.down"
      case 2: return "folder"
      case 3: return "doc.text"
      case 4: return "text.quote"
      case 5: return "checkmark.circle"
      default: return "gearshape.2"
    }
  }

  private func wizardStepIcon(_ systemName: String) -> some View {
    Image(systemName: systemName)
      .font(.system(size: 42, weight: .medium))
      .foregroundStyle(.tint)
      .frame(width: 100, height: 100)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 20))
      .padding()
      .accessibilityHidden(true)
  }

  private func selectExportInputFile() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [UTType(filenameExtension: "data") ?? .data]
    guard panel.runModal() == .OK, let url = panel.url else { return }

    exportInputError = nil
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    do {
      let metadata = try BORGVRMetaData(url: url)
      exportInputURL = url
      exportInputFile = url.path
      exportLevel = 0
      exportLevelDescriptions = metadata.levelMetadata.map { level in
        String(
          format: NSLocalizedString("converter_export_resolution_format", comment: ""),
          level.size.x,
          level.size.y,
          level.size.z
        )
      }
      exportOutputFile = url.deletingPathExtension()
        .appendingPathExtension("nrrd").path
      exportOutputURL = nil
    } catch {
      logger.error(error.localizedDescription)
      exportInputURL = nil
      exportInputFile = ""
      exportLevelDescriptions = []
      exportInputError = String(
        format: NSLocalizedString("converter_export_invalid_input_format", comment: ""),
        error.localizedDescription
      )
    }
  }

  private func selectExportOutputFile() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "nrrd") ?? .data]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = exportOutputFile.isEmpty
      ? "volume.nrrd"
      : URL(fileURLWithPath: exportOutputFile).lastPathComponent
    if !exportOutputFile.isEmpty {
      panel.directoryURL = URL(fileURLWithPath: exportOutputFile).deletingLastPathComponent()
    }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let outputURL = url.pathExtension.isEmpty ? url.appendingPathExtension("nrrd") : url
    exportOutputURL = outputURL
    exportOutputFile = outputURL.path
  }

  private func startExport() {
    guard !exportInputFile.isEmpty, !exportOutputFile.isEmpty else { return }
    isConverting = true
    exportDidFinish = false
    exportDidSucceed = false
    logText = ""
    let inputURL = exportInputURL ?? URL(fileURLWithPath: exportInputFile)
    let outputURL = exportOutputURL ?? URL(fileURLWithPath: exportOutputFile)
    let level = exportLevel
    let inputAccess = inputURL.startAccessingSecurityScopedResource()
    let outputDirectory = outputURL.deletingLastPathComponent()
    let outputAccess = outputDirectory.startAccessingSecurityScopedResource()
    DispatchQueue.global(qos: .userInitiated).async {
      var didSucceed = false
      defer {
        if inputAccess { inputURL.stopAccessingSecurityScopedResource() }
        if outputAccess { outputDirectory.stopAccessingSecurityScopedResource() }
      }
      do {
        _ = try BORGVRVolumeExporter.export(
          inputURL: inputURL,
          outputURL: outputURL,
          level: level,
          logger: logger
        )
        didSucceed = true
      } catch {
        logger.error(error.localizedDescription)
      }
      DispatchQueue.main.async {
        isConverting = false
        exportDidFinish = true
        exportDidSucceed = didSucceed
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
       let nhdrType = UTType(filenameExtension: "nhdr"),
       let pvmType = UTType(filenameExtension: "pvm") {
      panel.allowedContentTypes = [qvisType, nrrdType, nhdrType, pvmType]
    }
    if panel.runModal() == .OK, let url = panel.url {
      if url.startAccessingSecurityScopedResource() {
        defer { url.stopAccessingSecurityScopedResource() }
        inputFile = url.path
        inputDirectory = ""
        outputFile = URL(fileURLWithPath: inputFile)
          .deletingPathExtension().lastPathComponent
        datasetDescription = String(
          format: NSLocalizedString("converter_desc_from_file", comment: ""),
          outputFile
        )
      } else {
        logger.error(
          L(
            "converter_log_error_access_file_sandbox",
            comment: "Log: cannot access selected file due to sandbox"
          )
        )
      }
    }
  }

  private func validateBrickSize() {
    if let size = Int(tempBrickSize), size >= 1 + storedAppModel.brickOverlap * 2 {
      storedAppModel.brickSize = size
      brickSizeErrorMsg = nil
    } else {
      brickSizeErrorMsg = NSLocalizedString("converter_error_bricksize", comment: "")
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

        dicomPreviewModel.setDirectory(url)

        inputDirectory = url.path
        inputFile = ""
        (outputFile, datasetDescription) = generateDescriptionSuggestion(from: inputDirectory)
      } else {
        logger.error(
          L(
            "converter_log_error_access_directory_sandbox",
            comment: "Log: cannot access selected directory due to sandbox"
          )
        )
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
   - bytesPerComponent: The number of bytes per component in the volume.
   - componentCount: The number of components stored for each voxel.
   - voxelSpacing: A vector containing the physical spacing of one voxel along each axis.
   - overlap: The overlap between adjacent bricks.
   - outputFilename: The name of the output file to create.
   - description: A short description of the dataset.
   - Throws: An error if reading or reorganizing the volume fails.
   */
  func convertRawVolume(
    inputFilename: String,
    offset: Int,
    size: Vec3<Int>,
    maxBrickSize: Int,
    bytesPerComponent: Int,
    componentCount: Int,
    voxelSpacing: Vec3<Float>,
    overlap: Int,
    outputFilename: String,
    datasetDescription: String,
    metaDescription: String,
    useCompressor: Bool,
    extensionStrategy: ExtensionStrategy
  ) throws {
    let volume = try RawFileAccessor(
      filename: inputFilename,
      size: size,
      bytesPerComponent: bytesPerComponent,
      componentCount: componentCount,
      voxelSpacing: voxelSpacing,
      offset: offset,
      readOnly: true
    )

    // Create a reorganizer to partition the volume into bricks.
    let reorganizer = BrickedVolumeReorganizer(
      inputVolume: volume,
      brickSize: maxBrickSize,
      overlap: overlap,
      extensionStrategy: extensionStrategy
    )
    try reorganizer
      .reorganize(
        to: outputFilename,
        datasetDescription: datasetDescription,
        metaDescription: metaDescription,
        useCompressor: useCompressor,
        logger: logger
      )
  }

  /// Starts the conversion process.
  /// In this demo, the conversion process is simulated with a loop.
  func startConversion() {
    guard (!inputFile.isEmpty || !inputDirectory.isEmpty), !outputFile.isEmpty else {
      logger.error(
        L(
          "converter_log_error_missing_input_or_output",
          comment: "Log: missing input or output"
        )
      )
      return
    }

    logger.info(
      L(
        "converter_log_info_starting_conversion",
        comment: "Log: starting conversion"
      )
    )
#if DEBUG
    logger.warning(
      L(
        "converter_log_warning_debug_mode",
        comment: "Log: debug mode warning"
      )
    )
#endif
    isConverting = true

    // Run the conversion on a background thread.
    DispatchQueue.global(qos: .userInteractive).async {
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
            logger.error(
              String(
                format: L(
                  "converter_log_error_unsupported_border_mode_fallback_zeroes",
                  comment: "Log: unsupported border mode, falling back to zeroes"
                ),
                storedAppModel.borderModeString
              )
            )
        }

        if inputFile != "" {
          let sourceURL = URL(fileURLWithPath: inputFile)
          let parser = try VolumeFileParserFactory.parser(for: inputFile)
          defer {
            if parser.dataIsTempCopy {
              try? FileManager.default.removeItem(atPath: parser.absoluteFilename)
            }
          }
          let descriptionKey: String
          switch sourceURL.pathExtension.lowercased() {
            case "dat": descriptionKey = "converter_desc_from_qvis"
            case "pvm": descriptionKey = "converter_desc_from_pvm"
            default: descriptionKey = "converter_desc_from_nrrd"
          }
          let sourceDescription = String(
            format: NSLocalizedString(descriptionKey, comment: ""),
            sourceURL.deletingPathExtension().lastPathComponent
          )

          try convertRawVolume(
            inputFilename: parser.absoluteFilename,
            offset: parser.offset,
            size: parser.size,
            maxBrickSize: bricksize,
            bytesPerComponent: parser.bytesPerComponent,
            componentCount: parser.components,
            voxelSpacing: parser.voxelSpacing,
            overlap: storedAppModel.brickOverlap,
            outputFilename: appendExtensionIfNeeded(to: outputFilePath, ext: "data"),
            datasetDescription: datasetDescription.isEmpty
              ? sourceDescription
              : datasetDescription,
            metaDescription: sourceDescription,
            useCompressor: storedAppModel.enableCompression,
            extensionStrategy: borderMode
          )
        } else {
          let directory = URL(fileURLWithPath: inputDirectory, isDirectory: true)
          let dicomVolume = try getDicomVolume(directory: directory)

          let tempDir = FileManager.default.temporaryDirectory
          let uuid = UUID().uuidString
          let tempURL = tempDir.appendingPathComponent(uuid)

          logger.info(
            L(
              "converter_log_info_converting_dicom_to_temp_raw",
              comment: "Log: converting DICOM stack to temporary raw file"
            )
          )

          try dicomVolume.voxelData.withUnsafeBytes { try Data($0).write(to: tempURL) }

          let dirName = URL(fileURLWithPath: inputDirectory).lastPathComponent

          logger.info(
            L(
              "converter_log_info_converting_raw_to_borgvr",
              comment: "Log: converting raw file to BorgVR format"
            )
          )

          try convertRawVolume(
            inputFilename: tempURL.path,
            offset: 0,
            size: Vec3<Int>(
              x: dicomVolume.width,
              y: dicomVolume.height,
              z: dicomVolume.depth
            ),
            maxBrickSize: bricksize,
            bytesPerComponent: dicomVolume.bytesPerVoxel,
            componentCount: 1,
            voxelSpacing: Vec3<Float>(
              x: dicomVolume.voxelSpacing.x,
              y: dicomVolume.voxelSpacing.y,
              z: dicomVolume.voxelSpacing.z
            ),
            overlap: storedAppModel.brickOverlap,
            outputFilename: appendExtensionIfNeeded(to: outputFilePath, ext: "data"),
            datasetDescription: datasetDescription == ""
            ? String(
              format: NSLocalizedString("converter_desc_from_dicom_stack", comment: ""),
              dirName
            )
            : datasetDescription,
            metaDescription: String(
              format: NSLocalizedString("converter_desc_from_dicom_stack", comment: ""),
              dirName
            ),
            useCompressor: storedAppModel.enableCompression,
            extensionStrategy: borderMode
          )

          try FileManager.default.removeItem(at: tempURL)
        }
      } catch let error as QVISParser.Error {
        logger.error(
          String(
            format: L(
              "converter_log_error_qvisparser",
              comment: "Log: QVISParser error"
            ),
            error.localizedDescription
          )
        )
      } catch let error as NRRDParser.Error {
        logger.error(
          String(
            format: L(
              "converter_log_error_nrrdparser",
              comment: "Log: NRRDParser error"
            ),
            error.localizedDescription
          )
        )
      } catch let error as PVMParser.Error {
        logger.error("PVMParser Error: \(error.localizedDescription)")
      } catch let error as RawFileAccessor.Error {
        logger.error(
          String(
            format: L(
              "converter_log_error_rawfileaccessor",
              comment: "Log: RawFileAccessor error"
            ),
            error.localizedDescription
          )
        )
      } catch let error as MemoryMappedFile.Error {
        logger.error(
          String(
            format: L(
              "converter_log_error_memorymappedfile",
              comment: "Log: MemoryMappedFile error"
            ),
            error.localizedDescription
          )
        )
      } catch {
        logger.error(
          String(
            format: L(
              "converter_log_error_unexpected",
              comment: "Log: unexpected error"
            ),
            error.localizedDescription
          )
        )
      }
      DispatchQueue.main.async {
        isConverting = false
      }
      let total = timer.stop()
      logger.info(
        String(
          format: L(
            "converter_log_info_time_elapsed",
            comment: "Log: time elapsed for conversion"
          ),
          total
        )
      )
    }
  }

  func getDicomVolume(directory: URL) throws -> DicomParser.DicomVolume {
    let fileManager = FileManager.default
    let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    let dicomFiles = files.filter { $0.isFileURL }

    logger.info(
      L(
        "converter_log_info_scanning_dicom_dir",
        comment: "Log: scanning directory for DICOM files"
      )
    )

    guard !dicomFiles.isEmpty else {
      logger.error(
        L(
          "converter_log_error_no_files_in_directory",
          comment: "Log: no files found in directory"
        )
      )
      throw DicomParser.DicomParsingError.noValidFilesFound
    }

    logger.info(
      String(
        format: L(
          "converter_log_info_found_dicom_files",
          comment: "Log: number of found DICOM files"
        ),
        dicomFiles.count
      )
    )

    return try DicomParser.decodeVolume(from: dicomFiles)
  }

  func firstValidDicom(in urls: [URL]) -> DicomParser.DicomFile? {
    for url in urls where url.isFileURL {
      if let file = try? DicomParser.parseDicomHeader(from: url) {
        return file
      }
    }
    return nil
  }


  func generateDescriptionSuggestion(from directoryString: String) -> (String, String) {

    let directory = URL(fileURLWithPath: directoryString, isDirectory: true)

    do {
      let fileManager = FileManager.default
      let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      let potentialDicomFiles = files.filter { $0.isFileURL }

      guard potentialDicomFiles.isEmpty == false else {
        throw NSError(domain: "", code: 0)
      }

      func genTitle(slice: DicomParser.DicomSlice) -> String {
        var parts: [String] = []
        if let modality = slice.modality {
          parts.append(
            String(
              format: NSLocalizedString("converter_dicom_scan_with_modality", comment: ""),
              modality
            )
          )
        } else {
          parts.append(NSLocalizedString("converter_dicom_scan_generic", comment: ""))
        }
        if let name = slice.patientName {
          parts.append(
            String(
              format: NSLocalizedString("converter_dicom_of_name", comment: ""),
              name
            )
          )
        }
        if let date = slice.seriesDate {
          parts.append(
            String(
              format: NSLocalizedString("converter_dicom_at_date", comment: ""),
              date
            )
          )
        }
        return parts.joined(separator: " ").replacingOccurrences(of: "^", with: ", ")
      }


      guard let file = firstValidDicom(in: potentialDicomFiles) else {
        throw NSError(domain: "", code: 0)
      }
      let combined = genTitle(slice: try DicomParser.openSlice(from: file))

      if combined.isEmpty {
        return (
          URL(fileURLWithPath: inputDirectory).lastPathComponent,
          String(
            format: NSLocalizedString("converter_desc_from_dicom_directory", comment: ""),
            directory.lastPathComponent
          )
        )
      }

      return (
        URL(fileURLWithPath: inputDirectory).lastPathComponent,
        combined
      )

    } catch {
      return (
        URL(fileURLWithPath: inputDirectory).lastPathComponent,
        String(
          format: NSLocalizedString("converter_desc_from_dicom_directory", comment: ""),
          directory.lastPathComponent
        )
      )
    }
  }
}

// MARK: - Localized string helper

private func L(_ key: String, comment: String = "") -> String {
  NSLocalizedString(key, comment: comment)
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
