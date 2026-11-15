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
  @State private var additionalInputAccesses: [VolumeImportSourceAccess] = []
  @State private var supportingFileRequest: SupportingFileAccessRequest?
  @State private var retryAfterSupportingFileSelection = false
  @State private var fusionReference = VolumeFusionSelection()
  @State private var fusionRegistered = VolumeFusionSelection()
  @State private var fusionStep = VolumeFusionWizardStep.reference
  @State private var volumeStep = VolumeImportWizardStep.source
  @State private var filePickerMode: FilePickerView.Mode?
  @State private var datasetDescription = ""
  @State private var logText = ""
  @State private var showsImportLog = false
  @State private var progressText = ""
  @State private var progressValue = 0.0
  @State private var isWorking = false
  @State private var conversionCancellationToken: BorgVRVolumeConversionCancellationToken?
  @State private var conversionCancellationRequested = false
  @State private var returnToMainMenuAfterCancellation = false
  @State private var isExporting = false
  @State private var mode: Mode = .unknown

  private let logger = GUILogger()

  enum Mode {
    case unknown
    case copy
    case convert
    case dicom
    case volumeFusion
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
            total: nil,
            choices: importChoices,
            selectedID: pendingImportKind?.rawValue,
            canGoBack: !isWorking,
            showsNavigation: false,
            onBack: goBack,
            onNext: commitImportKind
          )
          .padding()
        } else {
          importWorkflow
        }
      }
      .buttonStyle(.bordered)
      .controlSize(.large)
      .buttonBorderShape(.roundedRectangle(radius: 8))
      .scrollDismissesKeyboard(.interactively)
      .toolbar {
        navigationControls
      }
      .sheet(item: $filePickerMode) { pickerMode in
        FilePickerView(mode: pickerMode) { access in
          filePickerMode = nil
          if let access {
            additionalInputAccesses = []
            importedDatasetURL = nil
            progressValue = 0
            progressText = ""
            logger.clear()
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
                      mode = .copy
                    default:
                      mode = VolumeFileParserFactory.supportedExtensions.contains(url.pathExtension.lowercased()) ? .convert : .unknown
                  }
                }
            }
            continueSourceSelection()
          }
        }
      }
      .sheet(item: $supportingFileRequest) { request in
        SupportingFileAccessPicker(request: request) { access in
          finishSupportingFileSelection(access, required: request.url)
          resumeImportAfterSupportingFileSelection()
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
      .onChange(of: isWorking) { _, working in
        if !working && returnToMainMenuAfterCancellation {
          appModel.navigationState = .start
        }
      }
    }
  }

  @ToolbarContentBuilder
  private var navigationControls: some ToolbarContent {
    ToolbarItemGroup(placement: .topBarTrailing) {
      Button(action: cancelImport) {
        Label("Cancel", systemImage: "xmark")
      }
      .disabled(openWorkflow.isOpening || (isWorking && conversionCancellationToken == nil))

      Button(action: goBack) {
        Label("Back", systemImage: "chevron.backward")
      }
      .disabled(isWorking || openWorkflow.isOpening)

      if choosingImportKind {
        Button(action: commitImportKind) {
          Label("converter_nav_next", systemImage: "chevron.forward")
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.accentColor)
        .disabled(pendingImportKind == nil || isWorking || openWorkflow.isOpening)
      } else if isChoosingSource {
        Button(action: continueSourceSelection) {
          Label("converter_nav_next", systemImage: "chevron.forward")
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.accentColor)
        // Refresh native highlighting when selecting a source enables the item.
        .id(canContinueSourceSelection)
        .disabled(!canContinueSourceSelection || isWorking || openWorkflow.isOpening)
      } else if isChoosingVolumeOptions {
        Button(action: continueVolumeOptions) {
          Label("converter_nav_next", systemImage: "chevron.forward")
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.accentColor)
        .id(canContinueImportOptions)
        .disabled(!canContinueImportOptions || isWorking || openWorkflow.isOpening)
      } else if !isWorking {
        if let importedDatasetURL {
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
        } else {
          Button {
            logger.clear()
            mode == .copy ? copyData() : startConversion(description: datasetDescription)
          } label: {
            Label(mode == .copy ? String(localized: "Copy data") : String(localized: "Start conversion"),
              systemImage: "tray.and.arrow.down")
          }
          .buttonStyle(.borderedProminent)
          .tint(Color.accentColor)
          .id(canStartImport)
          .disabled(!canStartImport || openWorkflow.isOpening)
        }
      }
    }
  }

  private var importWorkflow: some View {
    ScrollView {
      VStack(spacing: 14) {
        ConverterWizardHeader(title: "Import", step: currentImportStep,
          total: selectedImportKind?.compactWizardStepCount ?? 2)
        if let selectedImportKind {
          HStack {
            ConverterWizardStepIcon(systemImage: selectedImportKind.systemImage, compact: true)
            Text(selectedImportKind.title)
              .font(selectedImportKind == .volumeFusion ? .title2.weight(.semibold) : .headline)
            Spacer(minLength: 0)
          }
        }

        if isChoosingDICOMDirectory {
          Text("For a DICOM series, select the folder containing its slice files.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        if isChoosingFile || isChoosingDirectory {
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { sourceButtons }
            VStack(spacing: 12) { sourceButtons }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 16)
        }

        if selectedImportKind == .volumeFusion, let title = fusionStep.sourceTitle {
          VolumeFusionSourcePicker(title: title,
            selection: fusionStep == .reference ? $fusionReference : $fusionRegistered,
            onSourceSelected: continueSourceSelection)
          .id(fusionStep)
          .disabled(isWorking)
          .onChange(of: fusionReference.access?.url) { _, url in
            if url != nil { mode = .volumeFusion; importedDatasetURL = nil }
          }
          .onChange(of: fusionRegistered.access?.url) { _, url in
            if url != nil { mode = .volumeFusion; importedDatasetURL = nil }
          }
        } else if selectedImportKind != .volumeFusion, !isVolumeConversionPage {
          Text(inputFile.isEmpty ? String(localized: "No file selected") : inputFile)
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        if mode == .imageSequence, showsImportOptions { imageSequenceSizeFields }

        if (mode == .convert || mode == .copy || mode == .volumeFusion || mode == .imageSequence || mode == .dicom), showsImportOptions {
          Text(String(localized: "Import options", table: "ImportMessages"))
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if showsImportOptions && mode == .copy {
          Text(String(localized: "Existing metadata will be preserved.", table: "ImportMessages"))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if showsImportOptions && (mode == .convert || mode == .dicom || mode == .volumeFusion || mode == .imageSequence) {
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

        if isWorking || isVolumeConversionPage {
          conversionProgress
        }

        if !isChoosingSource && !isChoosingVolumeOptions { importLog }
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

  private var conversionProgress: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(importedDatasetURL != nil
        ? String(localized: "Import complete", table: "ImportMessages")
        : (progressText.isEmpty ? String(localized: "Ready to import", table: "ImportMessages") : progressText))
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      ProgressView(value: progressValue)
        .frame(maxWidth: .infinity)
      if isWorking {
        HStack(spacing: 12) {
          ProgressView()
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
      }
    }
  }

  private var importLog: some View {
    DisclosureGroup(isExpanded: $showsImportLog) {
      VStack(spacing: 12) {
        HStack {
          Spacer()
          HStack {
            Button { logger.clear() } label: {
              Label("Clear Log", systemImage: "trash")
            }
            .help("Clear Log")
            Button { isExporting = true } label: {
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
      .padding(.top, 8)
    } label: {
      Text(String(localized: "Details", table: "ImportMessages")).font(.headline)
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
        ConverterVolumeFormatButton(includesNativeBorgVR: true)
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
      case .volumeFusion, .none:
        EmptyView()
    }
  }

  private var importChoices: [ConverterChoiceItem] {
    VolumeImportKind.allCases.map { kind in
      ConverterChoiceItem(id: kind.rawValue, title: kind.title, systemImage: kind.systemImage,
        startsSection: kind == .volumeFusion) {
        commitImportKind(kind)
      }
    }
  }

  private func commitImportKind() {
    guard let kind = pendingImportKind else { return }
    commitImportKind(kind)
  }

  private func commitImportKind(_ kind: VolumeImportKind) {
    guard !isWorking else { return }
    pendingImportKind = kind
    if selectedImportKind != kind {
      importedDatasetURL = nil
      showsImportLog = false
      inputFile = ""
      inputAccess = nil
      additionalInputAccesses = []
      retryAfterSupportingFileSelection = false
      fusionReference = VolumeFusionSelection()
      fusionRegistered = VolumeFusionSelection()
      filePickerMode = nil
      datasetDescription = ""
      sourceNote = ""
      receivedAt = Date()
      imageSizeX = ""
      imageSizeY = ""
      imageSizeZ = ""
      logger.clear()
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
    fusionStep = .reference
    volumeStep = .source
    choosingImportKind = false
  }

  private func goBack() {
    guard !isWorking else { return }
    if choosingImportKind {
      appModel.navigationState = .start
    } else if usesVolumeWizard, let previous = volumeStep.previous {
      volumeStep = previous
    } else if selectedImportKind == .volumeFusion, let previous = fusionStep.previous {
      fusionStep = previous
    } else {
      choosingImportKind = true
    }
  }

  private func cancelImport() {
    guard !openWorkflow.isOpening, !isWorking || conversionCancellationToken != nil else { return }
    if isWorking {
      returnToMainMenuAfterCancellation = true
      cancelConversion()
    } else {
      appModel.navigationState = .start
    }
  }

  private var canStartImport: Bool {
    !isChoosingSource && (!usesVolumeWizard || volumeStep.canStart(
      sourceSelected: inputAccess != nil, sizeIsValid: hasValidImageSize))
      && mode != .unknown && (mode == .volumeFusion
      ? fusionStep.canStart(referenceSelected: fusionReference.input != nil,
          registeredSelected: fusionRegistered.input != nil) : inputAccess != nil)
  }

  private var isChoosingFusionSource: Bool {
    selectedImportKind == .volumeFusion && fusionStep.sourceTitle != nil
  }

  private var isChoosingImageDirectory: Bool {
    selectedImportKind == .imageSequence && volumeStep == .source
  }

  private var isChoosingDICOMDirectory: Bool {
    selectedImportKind == .dicomDirectory && volumeStep == .source
  }

  private var usesVolumeWizard: Bool {
    selectedImportKind == .dicomDirectory || selectedImportKind == .volumeFile || selectedImportKind == .imageSequence
  }

  private var isChoosingFile: Bool {
    selectedImportKind == .volumeFile && volumeStep == .source
  }

  private var isChoosingVolumeOptions: Bool {
    (usesVolumeWizard && volumeStep == .options) ||
      (selectedImportKind == .volumeFusion && fusionStep == .options)
  }

  private var isVolumeConversionPage: Bool {
    (usesVolumeWizard && volumeStep == .conversion) ||
      (selectedImportKind == .volumeFusion && fusionStep == .conversion)
  }

  private var showsImportOptions: Bool { !isChoosingSource && !isVolumeConversionPage }

  private var hasValidImageSize: Bool {
    selectedImportKind != .imageSequence || imageSequenceSize != nil
  }

  private var canContinueImportOptions: Bool {
    guard isChoosingVolumeOptions else { return false }
    if selectedImportKind == .volumeFusion {
      return fusionStep.canContinue(referenceSelected: fusionReference.input != nil,
        registeredSelected: fusionRegistered.input != nil)
    }
    return volumeStep.canContinue(
      sourceSelected: inputAccess != nil, sizeIsValid: hasValidImageSize)
  }

  private func continueVolumeOptions() {
    guard !isWorking, canContinueImportOptions else { return }
    showsImportLog = false
    if selectedImportKind == .volumeFusion { fusionStep = .conversion }
    else { volumeStep = .conversion }
  }

  private var isChoosingDirectory: Bool { isChoosingImageDirectory || isChoosingDICOMDirectory }
  private var isChoosingSource: Bool { isChoosingFusionSource || isChoosingDirectory || isChoosingFile }

  private var currentImportStep: Int {
    switch selectedImportKind {
      case .volumeFusion: fusionStep.number
      case .dicomDirectory, .volumeFile, .imageSequence: volumeStep.number
      default: 2
    }
  }

  private var canContinueSourceSelection: Bool {
    if isChoosingDICOMDirectory || isChoosingFile || isChoosingImageDirectory {
      return volumeStep.canContinue(sourceSelected: inputAccess != nil && mode != .unknown)
    }
    if isChoosingFusionSource {
      return fusionStep.canContinue(referenceSelected: fusionReference.input != nil,
        registeredSelected: fusionRegistered.input != nil)
    }
    return false
  }

  private func continueSourceSelection() {
    guard !isWorking, canContinueSourceSelection else { return }
    if usesVolumeWizard, let next = volumeStep.next { volumeStep = next }
    else if isChoosingFusionSource, let next = fusionStep.next { fusionStep = next }
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

  private func copyData() {
    guard !isWorking, !openWorkflow.isOpening, canStartImport, mode == .copy, let inputAccess else { return }
    importedDatasetURL = nil
    progressValue = 0
    progressText = String(localized: "Copying dataset", table: "ImportMessages")
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
        DispatchQueue.main.async {
          progressValue = 1
          importedDatasetURL = destinationURL
        }
        logger.info(String(format: String(localized: "log_copied_native_dataset_format"), destinationURL.lastPathComponent))
      } catch {
        logger.error(String(format: String(localized: "log_error_copying_file_format"), error.localizedDescription))
        DispatchQueue.main.async { progressText = String(localized: "Import Failed", table: "ImportMessages") }
      }
    }
  }

  private func startConversion(description: String) {
    importedDatasetURL = nil
    let provenance = sourceNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] :
      [BORGVRProvenanceEntry(sourceNote, date: receivedAt)]
    guard canStartImport,
          let inputAccess = mode == .volumeFusion ? fusionReference.access : self.inputAccess else {
      logger.error(String(localized: "Input file not specified."))
      return
    }

    let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let inputURL = inputAccess.url
    let imageExtent = mode == .imageSequence ? imageSequenceSize : nil
    let registeredInputAccess = mode == .volumeFusion ? fusionRegistered.access : nil
    let source: BorgVRVolumeConversionSource
    let stem: String
    if registeredInputAccess != nil {
      source = .registeredPair(reference: fusionReference.input!, moving: fusionRegistered.input!,
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
    let supportingAccesses = additionalInputAccesses
    conversionCancellationToken = cancellationToken
    conversionCancellationRequested = false
    isWorking = true
    progressValue = 0
    progressText = String(localized: "Reading volume", table: "ImportMessages")
    logger.info(String(format: String(localized: "log_starting_conversion_format"), outputFilename))

    DispatchQueue.global(qos: .userInitiated).async {
      defer { withExtendedLifetime((inputAccess, registeredInputAccess, supportingAccesses)) {} }
      let timer = HighResolutionTimer()
      timer.start()
      var requiredFileAccess: URL?
      defer {
        let fileRequiringAccess = requiredFileAccess
        DispatchQueue.main.async {
          conversionCancellationToken = nil
          conversionCancellationRequested = false
          isWorking = false
          if let fileRequiringAccess, !cancellationToken.isCancelled, !returnToMainMenuAfterCancellation {
            authorizeSupportingFile(fileRequiringAccess)
          } else {
            inputFile = ""
            self.inputAccess = nil
            additionalInputAccesses = []
            fusionReference = VolumeFusionSelection()
            fusionRegistered = VolumeFusionSelection()
            mode = .unknown
          }
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
        DispatchQueue.main.async {
          progressValue = 1
          importedDatasetURL = URL(fileURLWithPath: outputFile)
        }
      } catch BorgVRImportFileAccess.Error.permissionRequired(let url) {
        requiredFileAccess = url
      } catch is CancellationError {
        logger.info(String(localized: "Conversion cancelled."))
        DispatchQueue.main.async { progressText = String(localized: "Conversion cancelled.") }
      } catch {
        logger.error(String(format: String(localized: "log_import_failed_format"), error.localizedDescription))
        DispatchQueue.main.async { progressText = String(localized: "Import Failed", table: "ImportMessages") }
      }
    }
  }

  private func authorizeSupportingFile(_ requiredURL: URL) {
    let message = BorgVRImportFileAccess.Error.permissionRequired(requiredURL).localizedDescription
    progressText = message
    guard !additionalInputAccesses.contains(where: {
      BorgVRImportFileAccess.matchesSupportingFile($0.url, required: requiredURL)
    }) else {
      logger.error(message)
      return
    }
    supportingFileRequest = SupportingFileAccessRequest(url: requiredURL)
  }

  private func finishSupportingFileSelection(_ access: VolumeImportSourceAccess?, required: URL) {
    supportingFileRequest = nil
    retryAfterSupportingFileSelection = false
    guard let access else {
      progressText = String(localized: "Conversion cancelled.")
      logger.info(progressText)
      return
    }
    guard BorgVRImportFileAccess.matchesSupportingFile(access.url, required: required) else {
      progressText = String(format: String(localized: "Please select the referenced file \"%@\".",
        table: "ImportMessages"), required.lastPathComponent)
      logger.error(progressText)
      return
    }
    additionalInputAccesses.append(access)
    retryAfterSupportingFileSelection = true
  }

  private func resumeImportAfterSupportingFileSelection() {
    guard retryAfterSupportingFileSelection, !isWorking, !returnToMainMenuAfterCancellation else { return }
    retryAfterSupportingFileSelection = false
    startConversion(description: datasetDescription)
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
