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

  @Environment(RuntimeAppModel.self) private var runtimeAppModel
  @EnvironmentObject var storedAppModel: StoredAppModel
  @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
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
          Text("open_no_datasets_message")
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
              switch runtimeAppModel.immersiveSpaceState {
                case .open:
                  runtimeAppModel.immersiveSpaceState = .inTransition
                  await dismissImmersiveSpace()
                case .closed:
                  if let index = selectedIndex, datasets.indices.contains(index) {
                    switch datasets[index].source {
                      case .builtIn:
                        runtimeAppModel.startImmersiveSpace(
                          dataset: datasets[index],
                          asGroupSessionHost: true
                        )
                      case .local:
                        let documentsDirectory = FileManager.default.urls(
                          for: .documentDirectory,
                          in: .userDomainMask
                        ).first!

                        let localFilename = documentsDirectory
                          .appendingPathComponent(
                            (datasets[index].identifier)
                          ).relativePath

                        runtimeAppModel.startImmersiveSpace(
                          identifier: localFilename,
                          description: datasets[index].description,
                          source: datasets[index].source,
                          uniqueId: datasets[index].uniqueId,
                          asGroupSessionHost: true
                        )

                      case let .remote(addr, port, password):
                        if storedAppModel.progressiveLoading {
                          runtimeAppModel.startImmersiveSpace(
                            dataset: datasets[index],
                            asGroupSessionHost: true
                          )
                        } else {
                          downloadAndOpenSpace(
                            datasetID: datasets[index].identifier,
                            serverAddress: addr,
                            serverPort: port,
                            authSecret: password,
                            asGroupSessionHost: true
                          )
                        }
                    }
                  }

                case .inTransition:
                  break
              }
            }
          } label: {
            Text(
              runtimeAppModel.immersiveSpaceState == .open
              ? NSLocalizedString(
                "open_button_close_dataset",
                comment: "Button title: close dataset"
              )
              : NSLocalizedString(
                "open_button_open_dataset",
                comment: "Button title: open dataset"
              )
            )
          }
          .disabled(
            selectedIndex == nil
          )
          .animation(.none, value: 0)
          .fontWeight(.semibold)
          .buttonStyle(.borderedProminent)
          .padding()

          Button(action: {
            runtimeAppModel.currentState = .importData
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
            runtimeAppModel.currentState = .start
          }) {
            Text("open_button_back_to_main_menu")
          }
          .padding()
        }
        .onAppear {
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
      }

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
    .onAppear {
      runtimeAppModel.immersiveSpaceState = .closed
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
            logger: runtimeAppModel.logger,
            notifier: runtimeAppModel.notifier
          )
          try manager.connect(timeout: storedAppModel.timeout)
          let remoteDatasets = try manager.requestDatasetList()
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

    DispatchQueue.global(qos: .userInitiated).async {

      let logger: GUILogger = GUILogger()
      logger.setProgressBinding($prefetchStatusText, $prefetchProgress)
      logger.setMinimumLogLevel(.dev)
      var entryForLocalCopy: RuntimeAppModel.DatasetEntry? = nil

      do {
        let manager = BORGVRRemoteDataManager(
          host: serverAddress,
          port: UInt16(serverPort),
          authSecret: authSecret,
          logger: logger,
          notifier: nil
        )
        try manager.connect(timeout: storedAppModel.timeout)

        if let documentsURL = FileManager.default.urls(
          for: .documentDirectory,
          in: .userDomainMask
        ).first {

          let fileURL = documentsURL.appendingPathComponent(
            "\(datasetID).data"
          )

          let dataset = try manager.openDataset(
            datasetID: datasetID,
            timeout: storedAppModel.timeout,
            localCacheFilename: fileURL.path
          )

          entryForLocalCopy = RuntimeAppModel.DatasetEntry(
            identifier: fileURL.path,
            description: dataset.getMetadata().description,
            source: .local,
            uniqueId: dataset.getMetadata().uniqueID
          )

          let count = dataset.getMetadata().brickMetadata.count
          let b = dataset.allocateBrickBuffer()
          defer { b.deallocate() }
          for i in 0..<count {
            do {
              try dataset.getBrick(index: i, outputBuffer: b)
            } catch {
            }
          }

          DispatchQueue.main.async {
            prefetchStatusText = String(
              format: NSLocalizedString(
                "open_prefetch_loading_bricks_count",
                comment: "Prefetch status: loading N bricks"
              ),
              count
            )
          }

          while dataset.localRatio < 1.0 {
            if !prefetchContinue { break }
            let completed = Int(dataset.localRatio * Double(count))
            let percentString = String(
              format: "%.2f",
              dataset.localRatio * 100
            )
            DispatchQueue.main.async {
              prefetchProgress = dataset.localRatio
              prefetchStatusText = String(
                format: NSLocalizedString(
                  "open_prefetch_loading_bricks_progress",
                  comment: "Prefetch status with progress (completed, total, percent)"
                ),
                completed,
                count,
                percentString
              )
            }
            Thread.sleep(forTimeInterval: 1)
          }
        }
      } catch {
      }

      DispatchQueue.main.async {
        showPrefetchDialog = false
      }

      if prefetchContinue {
        Task { @MainActor in
          if let entryForLocalCopy {
            runtimeAppModel.startImmersiveSpace(
              dataset: entryForLocalCopy,
              asGroupSessionHost: asGroupSessionHost
            )
          }
        }
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

    if let datasetURLs = Bundle.main.urls(
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
