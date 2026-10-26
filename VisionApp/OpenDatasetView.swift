import SwiftUI

/**
 A view that displays available datasets and provides options to open, delete, and refresh them.

 This view interacts with the shared application model and immersive space environment to manage dataset
 operations and state transitions.
 */
struct OpenDatasetView: View {

  enum LoadingStage: Equatable {
    case idle
    case scanningFiles
    case loadingLocalDataset(String, Int, Int)
    case connectingServer(String, Int)

    var message: String {
      switch self {
        case .idle:
          return ""
        case .scanningFiles:
          return NSLocalizedString(
            "open_loading_scanning_files",
            comment: "Status text while scanning local files"
          )
        case .loadingLocalDataset(let name, let index, let total):
          return String(
            format: NSLocalizedString(
              "open_loading_local_dataset_format",
              comment: "Status text while loading local dataset (name, index, total)"
            ),
            name,
            index + 1,
            total
          )
        case let .connectingServer(address,port):
          return String(
            format: NSLocalizedString(
              "open_loading_connecting_server",
              comment: "Status text while connecting to server"
            ),
            address,
            port
          )
      }
    }

    var systemImage: String {
      switch self {
        case .idle:
          return ""
        case .scanningFiles:
          return "folder"
        case .loadingLocalDataset:
          return "doc.text"
        case .connectingServer:
          return "network"
      }
    }
  }

  @State private var datasets: [RuntimeAppModel.DatasetEntry] = []
  @State private var selectedIndex: Int?
  @State private var showDeleteConfirmation = false
  @State private var datasetToDelete: IndexSet?
  @State private var datasetToDeleteName: String?
  @State private var datasetToDeleteDescription: String?

  @State private var isLoading = false
  @State private var loadingStage: LoadingStage = .idle

  @State private var showPrefetchDialog = false
  @State private var prefetchProgress: Double = 0.0
  @State private var prefetchStatusText: String = NSLocalizedString(
    "open_prefetch_starting",
    comment: "Initial prefetch status text"
  )
  @State private var prefetchContinue = true
  @State private var prefetchWasCancelled = false
  @State private var prefetchCancellation: RemoteRequestCancellation?
  @State private var downloadError: String?

  @Environment(RuntimeAppModel.self) private var runtimeAppModel
  @EnvironmentObject var storedAppModel: StoredAppModel
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) var dismissWindow

  var body: some View {
    ZStack {
      VStack {
        Text("open_title_available_datasets")
          .font(.title2)
          .bold()
          .padding(.top)

        if datasets.isEmpty && !isLoading {
          Text("open_no_datasets_built_in_hidden_message")
            .padding()
        } else {
          List {
            ForEach(datasets.indices, id: \.self) { index in
              Button {
                selectedIndex = index
              } label: {
                HStack {
                  Image(
                    systemName: selectedIndex == index
                    ? "checkmark.circle.fill"
                    : iconForDatasetType(type: datasets[index].source)
                  )
                  .foregroundColor(selectedIndex == index ? .blue : .primary)

                  switch datasets[index].source {
                    case .local:
                      Text(
                        String(
                          format: NSLocalizedString(
                            "open_dataset_description_local_suffix",
                            comment: "Dataset description with local suffix"
                          ),
                          datasets[index].description
                        )
                      )
                    case let .remote(adress, port, _):
                      Text(
                        String(
                          format: NSLocalizedString(
                            "open_dataset_description_remote_suffix",
                            comment: "Dataset description with remote suffix"
                          ),
                          datasets[index].description,
                          adress,
                          port
                        )
                      )
                    case .builtIn:
                      Text(
                        String(
                          format: NSLocalizedString(
                            "open_dataset_description_built_in_suffix",
                            comment: "Dataset description with built-in suffix"
                          ),
                          datasets[index].description
                        )
                      )
                  }

                  Spacer()

                  if datasets[index].source == .local {
                    Button(action: {
                      datasetToDelete = IndexSet(integer: index)
                      datasetToDeleteName = datasets[index].identifier
                      datasetToDeleteDescription = datasets[index].description
                      showDeleteConfirmation = true
                    }) {
                      Image(systemName: "trash")
                        .foregroundColor(.red)
                    }
                    .buttonStyle(.borderless)
                  }
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .background(
                  RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.clear)
                )
                .overlay(
                  RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.clear, lineWidth: 1)
                )
              }
              .buttonStyle(.plain)
              .animation(.easeInOut(duration: 0.15), value: selectedIndex)
            }
          }
          .confirmationDialog(
            String(
              format: NSLocalizedString(
                "open_delete_confirmation_title",
                comment: "Confirm deletion of dataset (name)"
              ),
              datasetToDeleteDescription
              ?? NSLocalizedString(
                "open_delete_default_dataset_name",
                comment: "Fallback name for dataset in delete dialog"
              )
            ),
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
          ) {
            Button(
              NSLocalizedString(
                "open_cancel_button",
                comment: "Button title: cancel deletion"
              ),
              role: .close
            ) { }
            Button(
              NSLocalizedString(
                "open_delete_button",
                comment: "Button title: delete dataset"
              ),
              role: .destructive
            ) {
              if let datasetsToDelete = datasetToDelete,
                 let datasetToDelete = datasetsToDelete.first {
                deleteDataset(at: datasetToDelete)
                Task { await loadDatasetFilesAsync() }
              }
            }
          }
        }

        Spacer()

        HStack {
          Text("open_immersion_style_label")
            .foregroundColor(.gray)
            .padding()

          Picker(
            NSLocalizedString(
              "open_immersion_style_label",
              comment: "Label for immersion style picker"
            ),
            selection: Binding(
              get: { runtimeAppModel.mixedImmersionStyle },
              set: { newValue in runtimeAppModel.mixedImmersionStyle = newValue }
            )
          ) {
            Text("open_immersion_style_mixed").tag(true)
            Text("open_immersion_style_full").tag(false)
          }
          .pickerStyle(.segmented)
          .padding()

          Spacer()

          Button(action: openLoggerView) {
            Text("open_button_show_log")
              .font(.headline)
              .padding(.horizontal, 20)
              .padding(.vertical, 10)
          }
          .padding()
        }

        HStack {
          ShareLink(
            item: BorgVRActivity(),
            preview: SharePreview(
              NSLocalizedString(
                "mode_share_preview_title",
                comment: "Share preview title for BorgVR collaboration"
              )
            )
          )
          .hidden()

          Button {
            Task { @MainActor in
              if let index = selectedIndex, datasets.indices.contains(index) {
                let selected = datasets[index]
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                let editURL: URL?
                switch selected.source {
                  case .builtIn: editURL = nil
                  case .local:
                    editURL = selected.identifier.hasPrefix("/") ? URL(fileURLWithPath: selected.identifier) : documents?.appendingPathComponent(selected.identifier)
                  case .remote: editURL = documents?.appendingPathComponent("\(selected.uniqueId).data")
                }
                do { try await runtimeAppModel.volumeBrush.prepareOpening(datasetID: selected.uniqueId, datasetURL: editURL) }
                catch { return }
                switch selected.source {
                  case .builtIn:
                    runtimeAppModel.startImmersiveSpace(
                      dataset: selected,
                      asGroupSessionHost: true
                    )
                  case .local:
                    let documentsDirectory = FileManager.default.urls(
                      for: .documentDirectory,
                      in: .userDomainMask
                    ).first!

                    let localFilename = selected.identifier.hasPrefix("/") ? selected.identifier :
                      documentsDirectory.appendingPathComponent(selected.identifier).path

                    runtimeAppModel.startImmersiveSpace(
                      identifier: localFilename,
                      description: selected.description,
                      source: selected.source,
                      uniqueId: selected.uniqueId,
                      asGroupSessionHost: true
                    )

                  case let .remote(addr, port, password):
                    guard let resolvedDataset = await resolveRemoteDataset(
                      selected,
                      fallback: DatasetOrigin(address: addr, port: port, password: password)
                    ) else {
                      runtimeAppModel.logger.error(
                        "The dataset is not available from any known source."
                      )
                      return
                    }
                    if storedAppModel.progressiveLoading {
                      runtimeAppModel.startImmersiveSpace(
                        dataset: resolvedDataset,
                        asGroupSessionHost: true
                      )
                    } else {
                      guard case let .remote(resolvedAddress, resolvedPort, resolvedPassword) = resolvedDataset.source else {
                        return
                      }
                      downloadAndOpenSpace(
                        datasetID: resolvedDataset.identifier,
                        serverAddress: resolvedAddress,
                        serverPort: resolvedPort,
                        authSecret: resolvedPassword,
                        asGroupSessionHost: true
                      )
                    }
                }
              }
            }
          } label: {
            Text("open_button_open_dataset")
          }
          .disabled(
            selectedIndex == nil
          )
          .animation(.none, value: 0)
          .fontWeight(.semibold)
          .buttonStyle(.borderedProminent)
          .padding()

          Button(action: {
            runtimeAppModel.navigationState = .importData
          }) {
            Text("open_button_import_data")
          }

          Button(
            NSLocalizedString(
              "open_button_refresh_list",
              comment: "Button title: refresh dataset list"
            )
          ) {
            Task { await loadDatasetFilesAsync() }
          }
          .padding()

          Button(action: {
            runtimeAppModel.navigationState = .start
          }) {
            Text("open_button_back_to_main_menu")
          }
          .padding()
        }
        .onAppear {
          Task { await loadDatasetFilesAsync() }
        }
        .onDisappear { prefetchCancellation?.cancel() }
        .onChange(of: storedAppModel.hideBuiltInDatasets) { _, _ in
          Task { await loadDatasetFilesAsync() }
        }
      }
      .sheet(isPresented: $showPrefetchDialog) {
        PrefetchDialog(
          isPresented: $showPrefetchDialog,
          progress: $prefetchProgress,
          statusText: $prefetchStatusText,
          continueExecution: $prefetchContinue,
          wasCancelled: $prefetchWasCancelled
        )
        .onChange(of: prefetchContinue) { _, value in if !value { prefetchCancellation?.cancel() } }
      }
      .alert("Error", isPresented: Binding(get: { downloadError != nil }, set: { if !$0 { downloadError = nil } })) {
        Button("OK", role: .cancel) { downloadError = nil }
      } message: { Text(downloadError ?? "") }

      if isLoading {
        ZStack {
          Color.black.opacity(0.3)
            .ignoresSafeArea()
            .transition(.opacity)
            .zIndex(1)
            .allowsHitTesting(true)

          VStack(spacing: 16) {
            ProgressView()
              .progressViewStyle(CircularProgressViewStyle(tint: .blue))
              .scaleEffect(1.5)

            Image(systemName: loadingStage.systemImage)
              .font(.system(size: 36))
              .foregroundColor(.blue)

            ProgressView(value: currentProgress(), total: totalProgress())
              .progressViewStyle(LinearProgressViewStyle(tint: .blue))
              .frame(width: 200)
              .transition(.opacity)
              .animation(.easeInOut(duration: 0.3), value: currentProgress())

            Text(loadingStage.message)
              .font(.headline)
              .foregroundColor(.primary)
              .transition(.opacity)
          }
          .padding(40)
          .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
              .fill(.ultraThinMaterial)
          )
          .shadow(radius: 10)
          .transition(.scale)
          .zIndex(2)
        }
        .animation(.easeInOut, value: isLoading)
      }
    }
  }

  private func currentProgress() -> Double {
    if case .loadingLocalDataset(_, let index, _) = loadingStage {
      return Double(index)
    }
    return 0
  }

  private func totalProgress() -> Double {
    if case .loadingLocalDataset(_, _, let total) = loadingStage {
      return Double(total)
    }
    return 1
  }

  private func deleteDataset(at index: Int) {
    let documentsDirectory = FileManager.default.urls(
      for: .documentDirectory,
      in: .userDomainMask
    ).first!
    let inputFile = documentsDirectory
      .appendingPathComponent((datasets[index].identifier)).relativePath
    let fileURL = URL(fileURLWithPath: inputFile)

    do {
      try FileManager.default.removeItem(at: fileURL)
      datasets.remove(at: index)
    } catch {
      runtimeAppModel.logger.error(
        String(
          format: NSLocalizedString(
            "open_error_deleting_file",
            comment: "Error deleting dataset file"
          ),
          error.localizedDescription
        )
      )
    }

    if let selected = selectedIndex, datasets.indices.contains(selected) == false {
      selectedIndex = nil
    }
  }

  private func openLoggerView() {
    dismissWindow(id: "LoggerView")
    openWindow(id: "LoggerView")
  }

  private func loadRemoteDatasets() async -> [RuntimeAppModel.DatasetEntry] {
    var datasets: [RuntimeAppModel.DatasetEntry] = []

    for server in storedAppModel.servers {

      if !server.address.isEmpty {
        await MainActor.run { loadingStage = .connectingServer(server.address,server.port) }
        do {
          let manager = BORGVRRemoteDataManager(
            host: server.address,
            port: UInt16(server.port),
            authSecret: server.password,
            logger: runtimeAppModel.logger
          )
          try manager.connect(timeout: storedAppModel.timeout)
          do {
            let syncedCount = try TransferFunctionCatalog.storeRemoteTransferFunctions(
              from: manager,
              logger: runtimeAppModel.logger
            )
            if syncedCount > 0 {
              runtimeAppModel.logger.info("Synced \(syncedCount) transfer functions from \(server.address):\(server.port).")
            }
          } catch {
            runtimeAppModel.logger.warning(
              "Transfer function sync failed for \(server.address):\(server.port): \(error.localizedDescription)"
            )
          }
          do {
            let syncedCount = try VolumeMarkerCatalog.storeRemoteMarkerFiles(
              from: manager,
              logger: runtimeAppModel.logger
            )
            if syncedCount > 0 {
              runtimeAppModel.logger.info("Synced \(syncedCount) marker files from \(server.address):\(server.port).")
            }
          } catch {
            runtimeAppModel.logger.warning(
              "Marker file sync failed for \(server.address):\(server.port): \(error.localizedDescription)"
            )
          }
          do {
            let syncedCount = try SceneMeshAssetCatalog.storeRemoteMeshes(
              from: manager,
              logger: runtimeAppModel.logger
            )
            if syncedCount > 0 {
              runtimeAppModel.logger.info(
                "Synced \(syncedCount) meshes from \(server.address):\(server.port)."
              )
            }
          } catch {
            runtimeAppModel.logger.warning(
              "Mesh sync failed for \(server.address):\(server.port): \(error.localizedDescription)"
            )
          }
          let remoteDatasets = try manager.requestDatasetList()
          DatasetOriginCatalog.shared.recordServerSnapshot(
            origin: DatasetOrigin(address: server.address, port: server.port, password: server.password),
            datasetIDs: remoteDatasets.map(\.id),
            allowsSharing: server.shareViaSharePlay
          )
          for dataset in remoteDatasets {
            datasets.append(
              RuntimeAppModel.DatasetEntry(
                identifier: dataset.id,
                description: dataset.description,
                source: .remote(
                  address: server.address,
                  port: server.port,
                  password: server.password
                ),
                uniqueId: dataset.id
              )
            )
          }
        } catch {
          runtimeAppModel.logger.error(
            String(
              format: NSLocalizedString(
                "open_error_connecting_remote_server",
                comment: "Error while connecting to remote server"
              ),
              error.localizedDescription
            )
          )
        }
      }
    }


    return datasets
  }

  private func resolveRemoteDataset(
    _ dataset: RuntimeAppModel.DatasetEntry,
    fallback: DatasetOrigin
  ) async -> RuntimeAppModel.DatasetEntry? {
    let origins = DatasetOriginCatalog.deduplicated(
      [fallback] + DatasetOriginCatalog.shared.origins(for: dataset.uniqueId)
    )
    let timeout = storedAppModel.timeout

    for origin in origins {
      let remoteDatasets = try? await Task.detached(priority: .userInitiated) {
        let manager = BORGVRRemoteDataManager(
          host: origin.address,
          port: UInt16(clamping: origin.port),
          authSecret: origin.password,
          logger: nil
        )
        try manager.connect(timeout: timeout)
        return try manager.requestDatasetList()
      }.value
      guard let remoteDatasets else { continue }
      DatasetOriginCatalog.shared.recordServerSnapshot(
        origin: origin,
        datasetIDs: remoteDatasets.map(\.id),
        allowsSharing: DatasetOriginCatalog.shared.sharingAllowed(for: origin)
      )
      guard remoteDatasets.contains(where: { $0.id == dataset.uniqueId }) else { continue }
      return RuntimeAppModel.DatasetEntry(
        identifier: dataset.uniqueId,
        description: dataset.description,
        source: .remote(address: origin.address, port: origin.port, password: origin.password),
        uniqueId: dataset.uniqueId
      )
    }
    return nil
  }

  private func iconForDatasetType(type: RuntimeAppModel.DatasetSource) -> String {
    switch type {
      case .local:
        return "doc.fill"
      case .builtIn:
        return "internaldrive"
      case .remote:
        return "network"
    }
  }

  private func downloadAndOpenSpace(
    datasetID: String,
    serverAddress: String,
    serverPort: Int,
    authSecret: String,
    asGroupSessionHost: Bool
  ) {
    prefetchProgress = 0.0
    prefetchStatusText = NSLocalizedString(
      "open_prefetch_initializing",
      comment: "Prefetch status: initializing"
    )
    prefetchContinue = true
    prefetchWasCancelled = false
    showPrefetchDialog = true


    prefetchCancellation?.cancel()
    let cancellation = RemoteRequestCancellation()
    prefetchCancellation = cancellation
    Task { @MainActor in
      defer {
        if prefetchCancellation === cancellation {
          showPrefetchDialog = false
          prefetchCancellation = nil
        }
      }
      do {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
          throw RemoteDatasetOpenError.documentsDirectoryUnavailable
        }
        let origin = DatasetOrigin(address: serverAddress, port: serverPort, password: authSecret)
        let url = try await RemoteDatasetDownloader.download(datasetID: datasetID, origin: origin,
          to: documents.appendingPathComponent("\(datasetID).data"), timeout: storedAppModel.timeout,
          cancellation: cancellation,
          originProvider: { DatasetOriginCatalog.deduplicated([origin] + DatasetOriginCatalog.shared.origins(for: datasetID)) },
          progress: { value in
            Task { @MainActor in
              guard prefetchCancellation === cancellation, !cancellation.isCancelled else { return }
              prefetchProgress = value
              prefetchStatusText = value.formatted(.percent.precision(.fractionLength(1)))
            }
          })
        guard prefetchCancellation === cancellation, !cancellation.isCancelled, prefetchContinue else { return }
        let metadata = try BORGVRMetaData(url: url)
        runtimeAppModel.startImmersiveSpace(dataset: .init(identifier: url.path,
          description: metadata.datasetDescription, source: .local, uniqueId: metadata.uniqueID),
          asGroupSessionHost: asGroupSessionHost)
      } catch is CancellationError {
      } catch {
        guard prefetchCancellation === cancellation, !cancellation.isCancelled else { return }
        runtimeAppModel.logger.error("Could not download dataset: \(error.localizedDescription)")
        downloadError = error.localizedDescription
      }
    }
  }

  private func listLocalDataset() async -> [RuntimeAppModel.DatasetEntry] {
    var datasets: [RuntimeAppModel.DatasetEntry] = []

    let fileManager = FileManager.default
    if let documentsURL = fileManager.urls(
      for: .documentDirectory,
      in: .userDomainMask
    ).first {
      do {
        let files = try fileManager.contentsOfDirectory(
          at: documentsURL,
          includingPropertiesForKeys: nil
        )
        let datasetURLs = files.filter {
          $0.pathExtension.lowercased() == "data"
        }
        for (index, url) in datasetURLs.enumerated() {
          await MainActor.run {
            loadingStage = .loadingLocalDataset(
              url.lastPathComponent,
              index,
              datasetURLs.count
            )
          }
          try? await Task.sleep(nanoseconds: 10_000_000)
          if let data = try? BORGVRMetaData(url: url) {
            datasets.append(
              RuntimeAppModel.DatasetEntry(
                identifier: url.lastPathComponent,
                description: data.datasetDescription,
                source: .local,
                uniqueId: data.uniqueID
              )
            )
          }
        }
      } catch {
        runtimeAppModel.logger.error(
          String(
            format: NSLocalizedString(
              "open_error_loading_dataset_files",
              comment: "Error loading local dataset files"
            ),
            error.localizedDescription
          )
        )
      }
    }

    if !storedAppModel.hideBuiltInDatasets,
       let datasetURLs = Bundle.main.urls(
      forResourcesWithExtension: "data",
      subdirectory: nil
    ) {
      for (index, url) in datasetURLs.enumerated() {
        await MainActor.run {
          loadingStage = .loadingLocalDataset(
            url.lastPathComponent,
            index,
            datasetURLs.count
          )
        }
        try? await Task.sleep(nanoseconds: 10_000_000)

        if let data = try? BORGVRMetaData(url: url) {
          datasets.append(
            RuntimeAppModel.DatasetEntry(
              identifier: url.path(),
              description: data.datasetDescription,
              source: .builtIn,
              uniqueId: data.uniqueID
            )
          )
        }
      }
    }
    return datasets
  }

  private func loadDatasetFilesAsync() async {
    await MainActor.run {
      isLoading = true
      loadingStage = .scanningFiles
      selectedIndex = nil
      datasets.removeAll()
    }
    try? await Task.sleep(nanoseconds: 20_000_000)

    var loadedDatasets: [RuntimeAppModel.DatasetEntry] = await listLocalDataset()
    loadedDatasets.append(contentsOf: await loadRemoteDatasets())

    await MainActor.run {
      datasets = loadedDatasets.sorted { $0.description < $1.description }
      isLoading = false
      loadingStage = .idle
    }
  }
}
