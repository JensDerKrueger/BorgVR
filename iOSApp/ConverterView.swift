import SwiftUI
import UniformTypeIdentifiers

enum FileError: Error {
  case noPermission(String)
}

struct ConverterView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject var appSettings: AppSettings

  @State private var inputFile = ""
  @State private var datasetDescription = ""
  @State private var logText = ""
  @State private var progressText = ""
  @State private var progressValue = 0.0
  @State private var showFilePicker = false
  @State private var isWorking = false
  @State private var isExporting = false
  @State private var mode: Mode = .unknown

  private let logger = GUILogger()

  enum Mode {
    case unknown
    case copy
    case convert
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 14) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Unterstützt werden QVIS `.dat` + `.raw`, NRRD/NHDR und native BorgVR `.data`-Dateien.")
            .foregroundStyle(.secondary)
          Text("Bei `.dat` und `.nhdr` muss iOS auch Zugriff auf die referenzierte Rohdatei bekommen.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        HStack {
          Button {
            showFilePicker = true
          } label: {
            Label("Input-Volume auswählen", systemImage: "doc.badge.plus")
          }
          .disabled(isWorking)

          Text(inputFile.isEmpty ? String(localized: "Keine Datei ausgewählt") : inputFile)
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(.secondary)
        }

        if mode == .convert {
          TextField("Beschreibung für den Datensatz", text: $datasetDescription)
            .textFieldStyle(.roundedBorder)
        }

        HStack {
          Button(mode == .copy ? String(localized: "Data kopieren") : String(localized: "Konvertierung starten")) {
            logText = ""
            mode == .copy ? copyData() : startConversion(description: datasetDescription)
          }
          .buttonStyle(.borderedProminent)
          .disabled(isWorking || inputFile.isEmpty || mode == .unknown)

          if isWorking {
            ProgressView()
            ProgressView(value: progressValue)
              .frame(maxWidth: 220)
            Text(progressText)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        TextEditor(text: $logText)
          .font(.system(.body, design: .monospaced))
          .border(Color.secondary.opacity(0.35))
      }
      .padding()
      .navigationTitle("Import")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Zurück") { appModel.currentState = .start }
            .disabled(isWorking)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
          Button {
            logText = ""
          } label: {
            Label("Leeren", systemImage: "trash")
          }
          Button {
            isExporting = true
          } label: {
            Label("Export", systemImage: "square.and.arrow.up")
          }
        }
      }
      .sheet(isPresented: $showFilePicker) {
        FilePickerView { url in
          if let url {
            let fileExtension = url.pathExtension.lowercased()
            switch fileExtension {
              case "dat", "nrrd", "nhdr":
                mode = .convert
              case "data":
                mode = .copy
              default:
                mode = .unknown
            }
            inputFile = url.path
          } else {
            mode = .unknown
            inputFile = ""
          }
          showFilePicker = false
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

  private func copyData() {
    isWorking = true
    DispatchQueue.global(qos: .userInitiated).async {
      defer {
        DispatchQueue.main.async {
          isWorking = false
          inputFile = ""
          mode = .unknown
        }
      }

      let fileURL = URL(fileURLWithPath: inputFile)
      guard fileURL.startAccessingSecurityScopedResource() else {
        logger.error(String(format: String(localized: "error_no_permission_file_format"), fileURL.path))
        return
      }
      defer { fileURL.stopAccessingSecurityScopedResource() }

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
    guard !inputFile.isEmpty else {
      logger.error(String(localized: "Input file not specified."))
      return
    }

    let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let outputFilename = URL(fileURLWithPath: inputFile).deletingPathExtension().lastPathComponent + ".data"
    let outputFile = documentsDirectory.appendingPathComponent(outputFilename).path

    isWorking = true
    logger.info(String(format: String(localized: "log_starting_conversion_format"), outputFilename))

    DispatchQueue.global(qos: .userInitiated).async {
      let timer = HighResolutionTimer()
      timer.start()
      defer {
        DispatchQueue.main.async {
          isWorking = false
          inputFile = ""
          mode = .unknown
        }
      }

      do {
        let metadataURL = URL(fileURLWithPath: inputFile)
        guard metadataURL.startAccessingSecurityScopedResource() else {
          throw FileError.noPermission(String(format: String(localized: "error_no_permission_file_format"), metadataURL.path))
        }
        defer { metadataURL.stopAccessingSecurityScopedResource() }

        let parser: VolumeFileParser
        if metadataURL.pathExtension.lowercased() == "dat" {
          parser = try QVISParser(filename: inputFile)
        } else {
          parser = try NRRDParser(filename: inputFile)
        }

        let rawURL = URL(fileURLWithPath: parser.absoluteFilename)
        guard rawURL.startAccessingSecurityScopedResource() else {
          throw FileError.noPermission(String(format: String(localized: "error_no_permission_file_format"), rawURL.path))
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
        ? String(format: String(localized: "dataset_description_converted_from_format"), metadataURL.deletingPathExtension().lastPathComponent)
        : description

        let reorganizer = BrickedVolumeReorganizer(
          inputVolume: volume,
          brickSize: appSettings.brickSize,
          overlap: appSettings.brickOverlap,
          extensionStrategy: borderMode
        )
        try reorganizer.reorganize(
          to: outputFile,
          datasetDescription: actualDescription,
          metaDescription: String(localized: "Imported with BorgVR Mobile"),
          useCompressor: appSettings.enableCompression,
          logger: logger
        )
        logger.info(String(format: String(localized: "log_finished_conversion_format"), timer.stop()))
      } catch {
        logger.error(String(format: String(localized: "log_import_failed_format"), error.localizedDescription))
      }
    }
  }
}

extension UTType {
  static var volumeData: UTType {
    UTType(exportedAs: "de.cgvis.volumedata")
  }
}
