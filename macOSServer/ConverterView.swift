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
          .foregroundColor(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding()
        }
      }
      Spacer()

      HStack {
        VStack {
          Image("step\(step)")
            .resizable()
            .frame(width: 100, height: 100)
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .padding()
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
                  .foregroundColor(.gray)

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
                    .foregroundColor(inputFile.isEmpty ? .gray : .primary)
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
                    .foregroundColor(inputDirectory.isEmpty ? .gray : .primary)
                }
              }
            case 2:
              // Step 2: Output directory
              VStack(alignment: .leading, spacing: 12) {
                Text("converter_step2_title")
                  .font(.headline)
                Text("converter_step2_subtitle")
                  .font(.subheadline)
                  .foregroundColor(.gray)

                HStack {
                  Text("converter_label_data_directory")
                  TextField("converter_textfield_output_folder_placeholder", text: $storedAppModel.dataDirectory)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .accentColor(.blue)
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
                  .foregroundColor(.gray)

                HStack {
                  Text("converter_label_output_file")
                  TextField("converter_textfield_output_filename_placeholder", text: $outputFile)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .accentColor(.blue)
                }
              }
            case 4:
              // Step 4: Description
              VStack(alignment: .leading, spacing: 12) {
                Text("converter_step4_title")
                  .font(.headline)
                Text("converter_step4_subtitle")
                  .font(.subheadline)
                  .foregroundColor(.gray)

                HStack {
                  Text("converter_label_description")
                  TextField("converter_textfield_description_placeholder", text: $datasetDescription)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .accentColor(.blue)
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
                    .foregroundColor(.gray)
                  HStack(spacing: 8) {
                    Text("converter_label_bricksize")
                    TextField(
                      "converter_textfield_bricksize_placeholder",
                      text: $tempBrickSize,
                      onCommit: validateBrickSize
                    )
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
                Text("converter_converting_title")
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

  /// Presents an NSOpenPanel to allow file selection (macOS only).
  func selectInputFile() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowsOtherFileTypes = true
    if let qvisType = UTType(filenameExtension: "dat"),
       let nrrdType = UTType(filenameExtension: "nrrd"),
       let nhdrType = UTType(filenameExtension: "nhdr") {
      panel.allowedContentTypes = [qvisType, nrrdType, nhdrType]
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
   - bytesPerVoxel: The number of bytes per voxel in the volume.
   - aspect: A vector representing the aspect ratio scaling for the volume.
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
    bytesPerVoxel: Int,
    aspect: Vec3<Float>,
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

          let ext = URL(fileURLWithPath: inputFile).pathExtension

          if ext == "dat" {
            let parser = try QVISParser(filename: inputFile)
            let fileNameWithoutExtension =
            URL(fileURLWithPath: inputFile).deletingPathExtension().lastPathComponent

            try convertRawVolume(
              inputFilename: parser.absoluteFilename,
              offset: 0,
              size: parser.size,
              maxBrickSize: bricksize,
              bytesPerVoxel: parser.bytesPerComponent,
              aspect: parser.sliceThickness,
              overlap: storedAppModel.brickOverlap,
              outputFilename: appendExtensionIfNeeded(to: outputFilePath, ext: "data"),
              datasetDescription: datasetDescription == ""
              ? String(
                format: NSLocalizedString("converter_desc_from_qvis", comment: ""),
                fileNameWithoutExtension
              )
              : datasetDescription,
              metaDescription: String(
                format: NSLocalizedString("converter_desc_from_qvis", comment: ""),
                fileNameWithoutExtension
              ),
              useCompressor: storedAppModel.enableCompression,
              extensionStrategy: borderMode
            )
          } else {
            logger.info(
              L(
                "converter_log_info_opening_nrrd",
                comment: "Log: opening NRRD volume"
              )
            )

            let parser = try NRRDParser(filename: inputFile)

            let fileNameWithoutExtension =
            URL(fileURLWithPath: inputFile).deletingPathExtension().lastPathComponent

            logger.info(
              L(
                "converter_log_info_converting_nrrd",
                comment: "Log: converting NRRD to BorgVR format"
              )
            )

            try convertRawVolume(
              inputFilename: parser.absoluteFilename,
              offset: parser.offset,
              size: parser.size,
              maxBrickSize: bricksize,
              bytesPerVoxel: parser.bytesPerComponent,
              aspect: parser.sliceThickness,
              overlap: storedAppModel.brickOverlap,
              outputFilename: appendExtensionIfNeeded(to: outputFilePath, ext: "data"),
              datasetDescription: datasetDescription == ""
              ? String(
                format: NSLocalizedString("converter_desc_from_nrrd", comment: ""),
                fileNameWithoutExtension
              )
              : datasetDescription,
              metaDescription: String(
                format: NSLocalizedString("converter_desc_from_nrrd", comment: ""),
                fileNameWithoutExtension
              ),
              useCompressor: storedAppModel.enableCompression,
              extensionStrategy: borderMode
            )

            if parser.dataIsTempCopy {
              try FileManager.default.removeItem(at: URL(fileURLWithPath: parser.absoluteFilename))
            }
          }
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
            bytesPerVoxel: dicomVolume.bytesPerVoxel,
            aspect: Vec3<Float>(
              x: dicomVolume.scale.x,
              y: dicomVolume.scale.y,
              z: dicomVolume.scale.z
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
