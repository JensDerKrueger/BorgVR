import SwiftUI
import UniformTypeIdentifiers

enum FileError: Error {
  case noPermission(String)
}

struct ConverterView: View {
  @State private var receivedAt = Date()
  @State private var sourceNote = ""
  @State private var imageSizeX = ""
  @State private var imageSizeY = ""
  @State private var imageSizeZ = ""
  @State private var selectedImportKind: VolumeImportKind?
  @State private var pendingImportKind: VolumeImportKind? = .volumeFile
  @State private var choosingImportKind = true
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject var appSettings: AppSettings
  @EnvironmentObject private var sharePlay: SharePlayCoordinator
  @StateObject private var openWorkflow = DatasetOpenWorkflow()
  @State private var importedDatasetURL: URL?

  @State private var inputFile = ""
  @State private var inputAccess: VolumeImportSourceAccess?
  @State private var registeredInputAccess: VolumeImportSourceAccess?
  @State private var filePickerMode: FilePickerView.Mode?
  @State private var datasetDescription = ""
  @State private var logText = ""
  @State private var progressText = ""
  @State private var progressValue = 0.0
  @State private var isWorking = false
  @State private var conversionCancellationToken: BorgVRVolumeConversionCancellationToken?
  @State private var conversionCancellationRequested = false
  @State private var isExporting = false
  @State private var mode: Mode = .unknown

  private let logger = GUILogger()

  enum Mode {
    case unknown
    case copy
    case convert
    case dicom
    case dicomFusion
    case imageSequence
  }

  var body: some View {
    NavigationStack {
      Group {
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
      .scrollDismissesKeyboard(.interactively)
      .toolbar {
        if !choosingImportKind {
          ToolbarItem(placement: .topBarLeading) {
            Button {
              goBack()
            } label: {
              Label("Back", systemImage: "chevron.backward")
            }
            .disabled(isWorking)
          }
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
              case .dicomDirectory, .zarrDirectory, .files, .imageSequence:
                inputAccess = access
                inputFile = url.path
                registeredInputAccess = nil
                if pickerMode == .imageSequence {
                  mode = .imageSequence
                } else if pickerMode == .dicomDirectory {
                  mode = .dicom
                } else if pickerMode == .zarrDirectory {
                  mode = .convert
                } else {
                  switch url.pathExtension.lowercased() {
                    case "data":
                      mode = .copy
                    default:
                      mode = VolumeFileParserFactory.supportedExtensions.contains(url.pathExtension.lowercased()) ? .convert : .unknown
                  }
                }
            }
          }
          filePickerMode = nil
        }
      }
      .fileExporter(
        isPresented: $isExporting,
        document: TextFileDocument(text: logText),
        contentType: .plainText,
        defaultFilename: "BorgVRMobile-Import"
      ) { _ in }
      .onAppear {
        logger.setLogBinding($logText)
        logger.setProgressBinding($progressText, $progressValue)
        logger.setMinimumLogLevel(.dev)
      }
    }
  }

  private var importWorkflow: some View {
    ScrollView {
      VStack(spacing: 14) {
        ConverterWizardHeader(title: "Import", step: 2, total: 2)
        if let selectedImportKind {
          HStack {
            ConverterWizardStepIcon(systemImage: selectedImportKind.systemImage, compact: true)
            Text(selectedImportKind.title).font(.headline)
            Spacer(minLength: 0)
          }
        }

        VStack(alignment: .leading, spacing: 8) {
          if selectedImportKind == .volumeFile {
            ConverterVolumeFormatList(includesNativeBorgVR: true)
            Text("For `.dat` and `.nhdr`, iOS also needs access to the referenced raw data file.")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else if selectedImportKind == .dicomDirectory || selectedImportKind == .dicomFusion {
            Text("For a DICOM series, select the folder containing its slice files.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if selectedImportKind != .dicomFusion {
          ViewThatFits(in: .horizontal) {
            HStack { sourceButtons }
            VStack(alignment: .leading) { sourceButtons }
          }
        }

        if selectedImportKind == .dicomFusion {
          VStack(alignment: .leading, spacing: 10) {
            dicomDirectoryRow("Reference series", access: inputAccess, pickerMode: .dicomReference)
            dicomDirectoryRow("Series to register", access: registeredInputAccess, pickerMode: .dicomRegistered)
          }
          .disabled(isWorking)
        } else {
          Text(inputFile.isEmpty ? String(localized: "No file selected") : inputFile)
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(.secondary)
        }

        if mode == .imageSequence { imageSequenceSizeFields }

        if mode == .convert || mode == .dicom || mode == .dicomFusion || mode == .imageSequence {
          TextField("Dataset description", text: $datasetDescription)
            .textFieldStyle(.roundedBorder)
            .disabled(isWorking)
          TextField("converter_source_note", text: $sourceNote)
            .textFieldStyle(.roundedBorder)
            .disabled(isWorking)
          DatePicker("converter_received_on", selection: $receivedAt, displayedComponents: [.date, .hourAndMinute])
            .datePickerStyle(.compact)
            .disabled(isWorking)
        }

        HStack {
          if !isWorking, let importedDatasetURL {
            Button {
              openWorkflow.startOpeningImportedDataset(
                at: importedDatasetURL, appModel: appModel, appSettings: appSettings,
                sharePlay: sharePlay,
                storage: DatasetStorageAccess(directoryURL: importedDatasetURL.deletingLastPathComponent())
              )
            } label: {
              Label("Open Dataset Now", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(openWorkflow.isOpening)
          }
          if !isWorking {
            Button(mode == .copy ? String(localized: "Copy data") : String(localized: "Start conversion")) {
              logText = ""
              mode == .copy ? copyData() : startConversion(description: datasetDescription)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canStartImport || openWorkflow.isOpening)
          }

          if isWorking {
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                ProgressView()
                ProgressView(value: progressValue)
                  .frame(maxWidth: .infinity)
                if conversionCancellationToken != nil {
                  Button(role: .cancel) {
                    cancelConversion()
                  } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                  }
                  .fixedSize()
                  .disabled(conversionCancellationRequested)
                }
              }
              Text(progressText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }

        VStack(spacing: 8) {
          HStack {
            Text("Import Log")
              .font(.headline)
            Spacer()
            HStack {
              Button {
                logText = ""
              } label: {
                Label("Clear Log", systemImage: "trash")
              }
              .help("Clear Log")
              Button {
                isExporting = true
              } label: {
                Label("Save Log", systemImage: "square.and.arrow.down")
              }
              .help("Save Log")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(logText.isEmpty)
          }
          Text(logText)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
            .padding(8)
            .border(Color.secondary.opacity(0.35))
        }
      }
      .padding()
      .alert("Dataset could not be opened", isPresented: Binding(
        get: { openWorkflow.openErrorMessage != nil },
        set: { if !$0 { openWorkflow.openErrorMessage = nil } }
      )) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(openWorkflow.openErrorMessage ?? "")
      }
    }
  }

  @ViewBuilder
  private var sourceButtons: some View {
    switch selectedImportKind {
      case .volumeFile:
        Button { filePickerMode = .files } label: {
          Label("Select input volume", systemImage: "doc.badge.plus")
        }
        .disabled(isWorking)
        Button { filePickerMode = .zarrDirectory } label: {
          Label("Select Zarr folder", systemImage: "folder")
        }
        .disabled(isWorking)
      case .dicomDirectory:
        Button { filePickerMode = .dicomDirectory } label: {
          Label("Select DICOM folder", systemImage: "folder")
        }
        .disabled(isWorking)
      case .imageSequence:
        Button { filePickerMode = .imageSequence } label: {
          Label("image_sequence_select", systemImage: "photo.on.rectangle.angled")
        }
        .disabled(isWorking)
      case .dicomFusion, .none:
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
      registeredInputAccess = nil
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
        case .dicomFusion: mode = .dicomFusion
        case .imageSequence: mode = .imageSequence
      }
    }
    selectedImportKind = kind
    choosingImportKind = false
  }

  private func goBack() {
    guard !isWorking else { return }
    if choosingImportKind {
      appModel.navigationState = .start
    } else {
      choosingImportKind = true
    }
  }

  private var canStartImport: Bool {
    mode != .unknown && inputAccess != nil && (mode != .dicomFusion || registeredInputAccess != nil)
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
  }

  private func copyData() {
    guard let inputAccess else { return }
    importedDatasetURL = nil
    isWorking = true
    DispatchQueue.global(qos: .userInitiated).async {
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

      let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
      let destinationURL = documentsDirectory.appendingPathComponent(fileURL.lastPathComponent)
      do {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
          try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: fileURL, to: destinationURL)
        DispatchQueue.main.async { importedDatasetURL = destinationURL }
        logger.info(String(format: String(localized: "log_copied_native_dataset_format"), destinationURL.lastPathComponent))
      } catch {
        logger.error(String(format: String(localized: "log_error_copying_file_format"), error.localizedDescription))
      }
    }
  }

  private func startConversion(description: String) {
    importedDatasetURL = nil
    let provenance = sourceNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] :
      [BORGVRProvenanceEntry(sourceNote, date: receivedAt)]
    guard canStartImport, let inputAccess else {
      logger.error(String(localized: "Input file not specified."))
      return
    }

    let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let inputURL = inputAccess.url
    let imageExtent = mode == .imageSequence ? imageSequenceSize : nil
    let registeredInputAccess = mode == .dicomFusion ? self.registeredInputAccess : nil
    let source: BorgVRVolumeConversionSource
    let stem: String
    if let registeredInputAccess {
      source = .registeredDICOMPair(reference: inputURL, moving: registeredInputAccess.url,
                                    filter: appSettings.dicomResamplingFilter)
      stem = inputURL.lastPathComponent + "-fused"
    } else {
      source = mode == .imageSequence ? .imageSequence(inputURL)
        : (mode == .dicom ? .dicomDirectory(inputURL) : .file(inputURL))
      stem = mode == .dicom || mode == .imageSequence
        ? inputURL.lastPathComponent : inputURL.deletingPathExtension().lastPathComponent
    }
    let outputFilename = stem + ".data"
    let outputFile = documentsDirectory.appendingPathComponent(outputFilename).path

    let cancellationToken = BorgVRVolumeConversionCancellationToken()
    conversionCancellationToken = cancellationToken
    conversionCancellationRequested = false
    isWorking = true
    logger.info(String(format: String(localized: "log_starting_conversion_format"), outputFilename))

    DispatchQueue.global(qos: .userInitiated).async {
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
        let borderMode: ExtensionStrategy
        switch appSettings.borderMode {
          case "border":
            borderMode = .clamp
          case "repeat":
            borderMode = .repeatValue
          default:
            borderMode = .fillZeroes
        }

        let actualDescription = description.isEmpty
        ? String(format: String(localized: "dataset_description_converted_from_format"), stem)
        : description

        try BorgVRVolumeConversionService.convert(
          BorgVRVolumeConversionRequest(
            source: source,
            destinationURL: URL(fileURLWithPath: outputFile),
            datasetDescription: actualDescription,
            metaDescription: String(localized: "Imported with BorgVR Mobile"),
            settings: BorgVRVolumeConversionSettings(
              brickSize: appSettings.brickSize,
              overlap: appSettings.brickOverlap,
              useCompression: appSettings.enableCompression,
              extensionStrategy: borderMode,
              quantizeTo8Bit: appSettings.quantizeImportsTo8Bit, colorCompression: appSettings.importColorCompression
            ),
            physicalSizeMeters: imageExtent,
            provenance: provenance
          ),
          logger: logger,
          cancellationToken: cancellationToken
        )
        logger.info(String(format: String(localized: "log_finished_conversion_format"), timer.stop()))
        DispatchQueue.main.async { importedDatasetURL = URL(fileURLWithPath: outputFile) }
      } catch is CancellationError {
        logger.info(String(localized: "Conversion cancelled."))
      } catch {
        logger.error(String(format: String(localized: "log_import_failed_format"), error.localizedDescription))
      }
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
