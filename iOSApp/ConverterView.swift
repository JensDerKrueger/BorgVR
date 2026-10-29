import SwiftUI
import UniformTypeIdentifiers

enum FileError: Error {
  case noPermission(String)
}

struct ConverterView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject var appSettings: AppSettings

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
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 14) {
          VStack(alignment: .leading, spacing: 8) {
            Text("Supported formats are QVIS `.dat` + `.raw`, NRRD/NHDR, PVM, IV3Dm (`.i3m` / `.i3m.zip`), and native BorgVR `.data` files.")
              .foregroundStyle(.secondary)
            Text("For `.dat` and `.nhdr`, iOS also needs access to the referenced raw data file.")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text("For a DICOM series, select the folder containing its slice files.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)

          ViewThatFits(in: .horizontal) {
            HStack { sourceButtons }
            VStack(alignment: .leading) { sourceButtons }
          }

          if mode == .dicomFusion {
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

          if mode == .convert || mode == .dicom || mode == .dicomFusion {
            TextField("Dataset description", text: $datasetDescription)
              .textFieldStyle(.roundedBorder)
              .disabled(isWorking)
          }

          HStack {
            if !isWorking {
              Button(mode == .copy ? String(localized: "Copy data") : String(localized: "Start conversion")) {
                logText = ""
                mode == .copy ? copyData() : startConversion(description: datasetDescription)
              }
              .buttonStyle(.borderedProminent)
              .disabled(!canStartImport)
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
      }
      .scrollDismissesKeyboard(.interactively)
      .navigationTitle("Import")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            appModel.navigationState = .start
          } label: {
            Label("Back", systemImage: "chevron.backward")
          }
            .disabled(isWorking)
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

  @ViewBuilder
  private var sourceButtons: some View {
    Button {
      filePickerMode = .files
    } label: {
      Label("Select input volume", systemImage: "doc.badge.plus")
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
  }

  private func copyData() {
    guard let inputAccess else { return }
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
        logger.info(String(format: String(localized: "log_copied_native_dataset_format"), destinationURL.lastPathComponent))
      } catch {
        logger.error(String(format: String(localized: "log_error_copying_file_format"), error.localizedDescription))
      }
    }
  }

  private func startConversion(description: String) {
    guard canStartImport, let inputAccess else {
      logger.error(String(localized: "Input file not specified."))
      return
    }

    let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let inputURL = inputAccess.url
    let registeredInputAccess = mode == .dicomFusion ? self.registeredInputAccess : nil
    let source: BorgVRVolumeConversionSource
    let stem: String
    if let registeredInputAccess {
      source = .registeredDICOMPair(reference: inputURL, moving: registeredInputAccess.url,
                                    filter: appSettings.dicomResamplingFilter)
      stem = inputURL.lastPathComponent + "-fused"
    } else {
      source = mode == .dicom ? .dicomDirectory(inputURL) : .file(inputURL)
      stem = mode == .dicom ? inputURL.lastPathComponent : inputURL.deletingPathExtension().lastPathComponent
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
              quantizeTo8Bit: appSettings.quantizeImportsTo8Bit
            )
          ),
          logger: logger,
          cancellationToken: cancellationToken
        )
        logger.info(String(format: String(localized: "log_finished_conversion_format"), timer.stop()))
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
