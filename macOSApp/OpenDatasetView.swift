import SwiftUI

private enum RemoteDatasetOpenError: LocalizedError {
  case documentsDirectoryUnavailable
  case downloadStalled
  case downloadCancelled

  var errorDescription: String? {
    switch self {
      case .documentsDirectoryUnavailable:
        return String(localized: "Das Dokumentenverzeichnis ist nicht verfügbar.")
      case .downloadStalled:
        return String(localized: "Der Remote-Download macht keinen Fortschritt mehr.")
      case .downloadCancelled:
        return String(localized: "Der Remote-Download wurde angehalten.")
    }
  }
}

private final class RemoteDatasetDownloadCancellation {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
}

struct OpenDatasetView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject var appSettings: AppSettings
  @EnvironmentObject private var storedAppModel: StoredAppModel
  @EnvironmentObject private var sharePlay: SharePlayCoordinator

  @State private var datasets: [AppModel.DatasetEntry] = []
  @State private var selectedDatasetKey: String?
  @State private var isLoading = true
  @State private var isOpening = false
  @State private var statusText = String(localized: "Lokale Datensätze werden gelesen ...")
  @State private var openProgress: Double?
  @State private var openingTask: Task<Void, Never>?
  @State private var downloadCancellation: RemoteDatasetDownloadCancellation?
  @State private var openErrorMessage: String?
  @State private var dataDirectoryAccessMessage: String?
  @State private var showDeleteConfirmation = false
  @State private var pendingDeleteKey: String?

  var body: some View {
    NavigationStack {
      Group {
        if isLoading && datasets.isEmpty {
          loadingPanel
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if datasets.isEmpty {
          ContentUnavailableView(
            "Keine Datensätze gefunden",
            systemImage: "externaldrive.badge.questionmark",
            description: Text(dataDirectoryAccessMessage ?? "Importiere einen Datensatz oder konfiguriere einen Remote-Server in den Einstellungen.")
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(datasets, id: \.selectionKey) { dataset in
                datasetRow(dataset)

                if dataset.selectionKey != datasets.last?.selectionKey {
                  Divider()
                    .padding(.leading, 52)
                }
              }
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .padding()
          }
          .background(Color(nsColor: .controlBackgroundColor))
        }
      }
      .overlay {
        if isOpening || (isLoading && !datasets.isEmpty) {
          loadingPanel
            .padding(22)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
      }
      .navigationTitle("Datensatz öffnen")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Zurück") { appModel.currentState = .start }
            .help("dataset_open_back_help")
        }
        ToolbarItemGroup(placement: .primaryAction) {
          Button {
            Task { await loadDatasetFiles() }
          } label: {
            Label("Aktualisieren", systemImage: "arrow.clockwise")
          }
          .help("dataset_open_refresh_help")
          Button {
            appModel.currentState = .importData
          } label: {
            Label("Import", systemImage: "square.and.arrow.down")
          }
          .help("dataset_open_import_help")
        }
        ToolbarItem(placement: .confirmationAction) {
          Button {
            startOpeningSelectedDataset()
          } label: {
            Label("Öffnen", systemImage: "play.fill")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .disabled(selectedDataset == nil || isLoading || isOpening)
          .help("dataset_open_open_help")
        }
      }
      .alert(
        "Datensatz konnte nicht geöffnet werden",
        isPresented: Binding(
          get: { openErrorMessage != nil },
          set: { if !$0 { openErrorMessage = nil } }
        )
      ) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(openErrorMessage ?? "")
      }
      .confirmationDialog("Datensatz löschen?", isPresented: $showDeleteConfirmation) {
        Button("Löschen", role: .destructive) {
          if let pendingDeleteKey {
            deleteDataset(withKey: pendingDeleteKey)
          }
        }
      }
      .task {
        await loadDatasetFiles()
      }
    }
  }

  private var loadingPanel: some View {
    VStack(spacing: 14) {
      if let openProgress {
        ProgressView(value: openProgress)
      } else {
        ProgressView()
      }
      Text(statusText)
        .foregroundStyle(.secondary)
      if openProgress != nil {
        Button("Jetzt stoppen und später fortsetzen") {
          downloadCancellation?.cancel()
          openingTask?.cancel()
        }
        .buttonStyle(.bordered)
        .help("dataset_open_stop_download_help")
      }
    }
  }

  private func datasetRow(_ dataset: AppModel.DatasetEntry) -> some View {
    HStack(spacing: 12) {
      Button {
        selectedDatasetKey = dataset.selectionKey
      } label: {
        HStack(spacing: 12) {
          Image(systemName: icon(for: dataset.source))
            .foregroundStyle(isSelected(dataset) ? .blue : .secondary)
            .frame(width: 24)

          VStack(alignment: .leading, spacing: 3) {
            Text(dataset.description)
              .font(.headline)
              .foregroundStyle(.primary)
              .lineLimit(2)
            Text(subtitle(for: dataset))
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }

          Spacer()

          if isSelected(dataset) {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(.blue)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .simultaneousGesture(
        TapGesture(count: 2).onEnded {
          startOpening(dataset)
        }
      )
      .help("dataset_open_select_help")

      if dataset.source == .local {
        Button(role: .destructive) {
          pendingDeleteKey = dataset.selectionKey
          showDeleteConfirmation = true
        } label: {
          Image(systemName: "trash")
        }
        .accessibilityLabel("Datensatz löschen")
        .help("Datensatz löschen")
        .buttonStyle(.borderless)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(isSelected(dataset) ? Color.accentColor.opacity(0.12) : Color.clear)
  }

  private var selectedDataset: AppModel.DatasetEntry? {
    guard let selectedDatasetKey else { return nil }
    return datasets.first { $0.selectionKey == selectedDatasetKey }
  }

  private func isSelected(_ dataset: AppModel.DatasetEntry) -> Bool {
    selectedDatasetKey == dataset.selectionKey
  }

  private func icon(for source: AppModel.DatasetSource) -> String {
    switch source {
      case .local: return "internaldrive"
      case .remote: return "network"
      case .builtIn: return "internaldrive"
    }
  }

  private func subtitle(for dataset: AppModel.DatasetEntry) -> String {
    if let metadataSummary = dataset.metadataSummary {
      return metadataSummary
    }

    switch dataset.source {
      case .local: return String(localized: "Lokal")
      case let .remote(address, port): return "Remote - \(address):\(port)"
      case .builtIn: return String(localized: "eingebaut")
    }
  }

  private func metadataSummary(for metadata: BORGVRMetaData) -> String {
    let bitsPerComponent = metadata.bytesPerComponent * 8
    let channelText = metadata.componentCount == 1
      ? String(localized: "1 Kanal")
      : String(format: String(localized: "metadata_channel_count_format"), metadata.componentCount)
    let compressionText = metadata.compression
      ? String(localized: "komprimiert")
      : String(localized: "unkomprimiert")
    let lodText = metadata.levelMetadata.count == 1
      ? String(localized: "1 LOD")
      : String(format: String(localized: "metadata_lod_count_format"), metadata.levelMetadata.count)

    return "\(metadata.width) x \(metadata.height) x \(metadata.depth) - " +
      "\(bitsPerComponent)-bit, \(channelText) - " +
      "\(String(localized: "Brick")) \(metadata.brickSize) - \(lodText) - " +
      "\(compressionText) - \(String(localized: "Werte")) \(metadata.minValue)...\(metadata.maxValue)"
  }

  private func startOpeningSelectedDataset() {
    guard let selectedDataset else { return }
    startOpening(selectedDataset)
  }

  private func startOpening(_ dataset: AppModel.DatasetEntry) {
    guard !isLoading && !isOpening else { return }
    selectedDatasetKey = dataset.selectionKey
    openingTask?.cancel()
    openingTask = Task { await openDatasetEntry(dataset) }
  }

  private func openDatasetEntry(_ dataset: AppModel.DatasetEntry) async {
    isOpening = true
    statusText = String(localized: "Datensatz wird geöffnet ...")
    defer {
      isOpening = false
      statusText = ""
      openProgress = nil
      openingTask = nil
      downloadCancellation = nil
    }

    do {
      if case .remote = dataset.source, !appSettings.progressiveLoading {
        let cancellation = RemoteDatasetDownloadCancellation()
        downloadCancellation = cancellation
        let localDataset = try await downloadRemoteDatasetBeforeOpening(
          dataset,
          cancellation: cancellation
        )
        openDataset(localDataset)
      } else {
        try await validateDatasetCanOpen(dataset)
        openDataset(dataset)
      }
    } catch RemoteDatasetOpenError.downloadCancelled {
      appModel.logger.info(String(localized: "Remote dataset download paused."))
    } catch {
      appModel.logger.error("Error opening dataset: \(error.localizedDescription)")
      openErrorMessage = "\(dataset.description)\n\n\(error.localizedDescription)"
      removeUnavailableRemoteEntries(matching: dataset)
    }
  }

  private func openDataset(_ dataset: AppModel.DatasetEntry) {
    switch dataset.source {
      case .local:
        let identifierPath = dataset.identifier.hasPrefix("/")
          ? dataset.identifier
          : dataDirectoryURL.appendingPathComponent(dataset.identifier).path
        appModel.activeDataset = AppModel.DatasetEntry(
          identifier: identifierPath,
          description: dataset.description,
          source: dataset.source,
          uniqueId: dataset.uniqueId,
          metadataSummary: dataset.metadataSummary
        )
      case .remote, .builtIn:
        appModel.activeDataset = dataset
    }
    if !sharePlay.isInSession {
      appModel.groupSessionHost = true
    }
    appModel.currentState = .renderData
    sharePlay.datasetOpened()
  }

  private func validateDatasetCanOpen(_ dataset: AppModel.DatasetEntry) async throws {
    guard case let .remote(address, port) = dataset.source else { return }

    let datasetID = dataset.identifier
    let timeout = appSettings.timeout
    try await Task.detached(priority: .userInitiated) {
      let manager = BORGVRRemoteDataManager(
        host: address,
        port: UInt16(port),
        logger: nil,
        notifier: nil
      )
      try manager.connect(timeout: timeout)
      _ = try manager.openDataset(datasetID: datasetID, timeout: timeout)
    }.value
  }

  private func downloadRemoteDatasetBeforeOpening(
    _ dataset: AppModel.DatasetEntry,
    cancellation: RemoteDatasetDownloadCancellation
  ) async throws -> AppModel.DatasetEntry {
    guard case let .remote(address, port) = dataset.source else { return dataset }

    let datasetID = dataset.identifier
    let timeout = appSettings.timeout
    let dataDirectoryAccessURL = storedAppModel.startAccessingDataDirectory()
    defer {
      storedAppModel.stopAccessingDataDirectory(dataDirectoryAccessURL)
    }
    let cacheURL = dataDirectoryURL.appendingPathComponent("\(datasetID).data")
    let cachePath = cacheURL.path
    let incompletePath = cachePath + ".incomplete"
    let stallTimeout = max(30.0, timeout * 10.0)

    statusText = String(localized: "Remote-Datensatz wird lokal geladen ...")
    openProgress = 0

    let localPath = try await Task.detached(priority: .userInitiated) {
      if cancellation.isCancelled {
        throw RemoteDatasetOpenError.downloadCancelled
      }

      let manager = BORGVRRemoteDataManager(
        host: address,
        port: UInt16(port),
        logger: nil,
        notifier: nil
      )
      try manager.connect(timeout: timeout)
      let remoteData = try manager.openDataset(
        datasetID: datasetID,
        timeout: timeout,
        localCacheFilename: cachePath
      )

      let brickCount = remoteData.getMetadata().brickMetadata.count
      let brickBuffer = remoteData.allocateBrickBuffer()
      defer { brickBuffer.deallocate() }

      await MainActor.run {
        statusText = remoteDatasetDownloadProgressText(progress: 0)
      }

      for index in 0..<brickCount {
        if cancellation.isCancelled {
          throw RemoteDatasetOpenError.downloadCancelled
        }
        do {
          try remoteData.getBrick(index: index, outputBuffer: brickBuffer)
        } catch {
        }
      }

      var lastProgress = -1.0
      var lastProgressDate = Date()
      let fileManager = FileManager.default

      while true {
        if cancellation.isCancelled {
          throw RemoteDatasetOpenError.downloadCancelled
        }

        let progress = remoteData.localRatio
        if progress > lastProgress + 0.001 {
          lastProgress = progress
          lastProgressDate = Date()
          await MainActor.run {
            openProgress = progress
            statusText = remoteDatasetDownloadProgressText(progress: progress)
          }
        }

        let completeFileExists = fileManager.fileExists(atPath: cachePath)
        let incompleteFileExists = fileManager.fileExists(atPath: incompletePath)
        if progress >= 1.0 && completeFileExists && !incompleteFileExists {
          break
        }

        if Date().timeIntervalSince(lastProgressDate) > stallTimeout {
          throw RemoteDatasetOpenError.downloadStalled
        }

        try await Task.sleep(nanoseconds: 200_000_000)
      }

      return remoteData.localFile ?? cachePath
    }.value

    let localMetadataSummary = (try? BORGVRMetaData(url: URL(fileURLWithPath: localPath)))
      .map { metadataSummary(for: $0) } ?? dataset.metadataSummary

    return AppModel.DatasetEntry(
      identifier: localPath,
      description: dataset.description,
      source: .local,
      uniqueId: dataset.uniqueId,
      metadataSummary: localMetadataSummary
    )
  }

  private func remoteDatasetDownloadProgressText(progress: Double) -> String {
    let percentage = progress.formatted(.percent.precision(.fractionLength(0)))
    return String(format: String(localized: "remote_dataset_download_progress_format"), percentage)
  }

  private func removeUnavailableRemoteEntries(matching dataset: AppModel.DatasetEntry) {
    guard case let .remote(address, port) = dataset.source else { return }
    datasets.removeAll {
      if case let .remote(candidateAddress, candidatePort) = $0.source {
        return candidateAddress == address && candidatePort == port
      }
      return false
    }
    selectedDatasetKey = nil
  }

  private func deleteDataset(withKey key: String) {
    guard let dataset = datasets.first(where: { $0.selectionKey == key }),
          dataset.source == .local else { return }
    let dataDirectoryAccessURL = storedAppModel.startAccessingDataDirectory()
    defer {
      storedAppModel.stopAccessingDataDirectory(dataDirectoryAccessURL)
    }
    let fileURL = dataset.identifier.hasPrefix("/")
      ? URL(fileURLWithPath: dataset.identifier)
      : dataDirectoryURL.appendingPathComponent(dataset.identifier)
    do {
      try FileManager.default.removeItem(at: fileURL)
      datasets.removeAll { $0.selectionKey == key }
      if selectedDatasetKey == key {
        selectedDatasetKey = nil
      }
    } catch {
      appModel.logger.error("Error deleting file: \(error.localizedDescription)")
    }
  }

  private func loadDatasetFiles() async {
    isLoading = true
    statusText = String(localized: "Lokale Datensätze werden gelesen ...")
    await Task.yield()
    var loadedDatasets = await loadLocalDatasets()

    statusText = String(localized: "Remote-Server wird geprüft ...")
    await Task.yield()
    loadedDatasets.append(contentsOf: await loadRemoteDatasets())

    datasets = loadedDatasets.sorted { $0.description < $1.description }
    if let selectedDatasetKey,
       !datasets.contains(where: { $0.selectionKey == selectedDatasetKey }) {
      self.selectedDatasetKey = nil
    }
    isLoading = false
    statusText = ""
  }

  private func loadLocalDatasets() async -> [AppModel.DatasetEntry] {
    var loaded: [AppModel.DatasetEntry] = []
    let fileManager = FileManager.default
    let dataDirectoryAccessURL = storedAppModel.startAccessingDataDirectory()
    defer {
      storedAppModel.stopAccessingDataDirectory(dataDirectoryAccessURL)
    }
    if let accessError = storedAppModel.lastDataDirectoryAccessError {
      dataDirectoryAccessMessage = accessError
      appModel.logger.error(accessError)
    } else {
      dataDirectoryAccessMessage = nil
    }
    let localDataDirectoryURL = dataDirectoryURL
    do {
      let files = try fileManager.contentsOfDirectory(at: localDataDirectoryURL, includingPropertiesForKeys: nil)
      for url in files where url.pathExtension.lowercased() == "data" {
        if let data = try? BORGVRFileData(filename: url.path) {
          let metadata = data.getMetadata()
          loaded.append(
            AppModel.DatasetEntry(
              identifier: url.path,
              description: metadata.datasetDescription,
              source: .local,
              uniqueId: metadata.uniqueID,
              metadataSummary: metadataSummary(for: metadata)
            )
          )
        }
      }
    } catch {
      let message = "Error loading dataset files in \(localDataDirectoryURL.path): \(error.localizedDescription)"
      dataDirectoryAccessMessage = message
      appModel.logger.error(message)
    }
    if let datasetURLs = Bundle.main.urls(forResourcesWithExtension: "data", subdirectory: nil) {
      for url in datasetURLs {
        if let metadata = try? BORGVRMetaData(url: url) {
          loaded.append(
            AppModel.DatasetEntry(
              identifier: url.path,
              description: metadata.datasetDescription,
              source: .builtIn,
              uniqueId: metadata.uniqueID,
              metadataSummary: metadataSummary(for: metadata)
            )
          )
        }
      }
    }
    return loaded
  }

  private var dataDirectoryURL: URL {
    storedAppModel.resolvedDataDirectoryURL()
  }

  private func loadRemoteDatasets() async -> [AppModel.DatasetEntry] {
    let servers = appSettings.servers.filter { !$0.address.isEmpty }
    let timeout = appSettings.timeout
    let logger = appModel.logger

    return await Task.detached(priority: .userInitiated) {
      var loaded: [AppModel.DatasetEntry] = []
      for server in servers {
        do {
          let manager = BORGVRRemoteDataManager(
            host: server.address,
            port: UInt16(server.port),
            logger: logger,
            notifier: nil
          )
          try manager.connect(timeout: timeout)
          for dataset in try manager.requestDatasetList() {
            loaded.append(
              AppModel.DatasetEntry(
                identifier: dataset.id,
                description: dataset.description,
                source: .remote(address: server.address, port: server.port),
                uniqueId: dataset.id,
                metadataSummary: nil
              )
            )
          }
        } catch {
          logger.error("Error connecting to remote server \(server.address):\(server.port): \(error.localizedDescription)")
        }
      }
      return loaded
    }.value
  }
}

private extension AppModel.DatasetEntry {
  var selectionKey: String {
    "\(source.selectionKey)|\(identifier)|\(uniqueId)"
  }
}

private extension AppModel.DatasetSource {
  var selectionKey: String {
    switch self {
      case .local:
        return "local"
      case .builtIn:
        return "builtIn"
      case let .remote(address, port):
        return "remote:\(address):\(port)"
    }
  }
}
