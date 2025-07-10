import SwiftUI

struct PrefetchDialog: View {
  @Binding var isPresented: Bool
  @Binding var progress: Double
  @Binding var statusText: String
  @Binding var continueExecution: Bool
  @Binding var wasCancelled: Bool

  var body: some View {
    VStack(spacing: 20) {
      Text("Prefetching Dataset")
        .font(.headline)

      Text(statusText)
        .font(.subheadline)
        .multilineTextAlignment(.center)

      ProgressView(value: progress)
        .progressViewStyle(LinearProgressViewStyle())
        .padding()

      ProgressView() // Busy spinner

      Button("Cancel and Resume Later") {
        continueExecution = false
        wasCancelled = true
        isPresented = false
      }
      .padding(.top, 10)
    }
    .padding()
    .frame(width: 300)
  }
}

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
    case connectingServer

    var message: String {
      switch self {
        case .idle:
          return ""
        case .scanningFiles:
          return "Scanning local files…"
        case .loadingLocalDataset(let name, let index, let total):
          return "Loading \(name) (\(index + 1) of \(total))…"
        case .connectingServer:
          return "Connecting to server…"
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

  @State private var datasets: [(String, String, AppModel.DatasetSource)] = []
  @State private var selectedIndex: Int?
  @State private var showDeleteConfirmation = false
  @State private var datasetToDelete: IndexSet?
  @State private var datasetToDeleteName: String?
  @State private var isLoading = false
  @State private var loadingStage: LoadingStage = .idle

  @State private var showDialog = false
  @State private var progress: Double = 0.0
  @State private var statusText: String = "Starting..."
  @State private var continueExecution = true
  @State private var wasCancelled = false

  @Environment(AppModel.self) private var appModel
  @EnvironmentObject var appSettings: AppSettings
  @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
  @Environment(\.openImmersiveSpace) private var openImmersiveSpace
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) var dismissWindow

  var body: some View {
    ZStack {
      VStack {
        Text("Available Datasets")
          .font(.title2)
          .bold()
          .padding(.top)

        if datasets.isEmpty && !isLoading {
          Text("""
  **No Valid Datasets Found**

  To add datasets, you have two options:

  - **Import Dataset:** Use the “Import a Dataset” option in the main menu.
  - **Connect to a Dataset Server:**  
    Enter the server address in the settings dialog and then return to this window.
""")
          .padding()
        } else {
          List {
            ForEach(datasets.indices, id: \.self) { index in
              HStack {
                Image(systemName: selectedIndex == index ? "checkmark.circle.fill" : "doc.fill")
                  .foregroundColor(selectedIndex == index ? .blue : .primary)

                switch datasets[index].2 {
                  case .Local:
                    Text(datasets[index].1 + " - Local")
                  case .Remote:
                    Text(datasets[index].1 + " - Remote")
                }

                Spacer()

                if datasets[index].2 == .Local {
                  Button(action: {
                    datasetToDelete = IndexSet(integer: index)
                    datasetToDeleteName = datasets[index].1
                    showDeleteConfirmation = true
                  }) {
                    Image(systemName: "trash")
                      .foregroundColor(.red)
                  }
                  .buttonStyle(.borderless)
                }
              }
              .contentShape(Rectangle())
              .onTapGesture {
                selectedIndex = index
              }
            }
          }
          .confirmationDialog(
            "Are you sure you want to delete \(datasetToDeleteName ?? "this dataset") ?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
          ) {
            Button("Delete", role: .destructive) {
              if let datasetsToDelete = datasetToDelete,
                 let datasetToDelete = datasetsToDelete.first {
                deleteDataset(at: datasetToDelete)
                Task { await loadDatasetFilesAsync() }
              }
            }
            Button("Cancel", role: .cancel) { }
          }
        }

        Spacer()

        HStack {
          Text("Immersion Style")
            .foregroundColor(.gray)
            .padding()

          Picker("Immersion Style", selection: Binding(
            get: { appModel.mixedImmersionStyle },
            set: { newValue in appModel.mixedImmersionStyle = newValue }
          )) {
            Text("Mixed (AR Mode)").tag(true)
            Text("Full (VR Mode)").tag(false)
          }
          .pickerStyle(.segmented)
          .padding()

          Spacer()
          
          Button(action: openLoggerView) {
            Text("Show Log")
              .font(.headline)
              .padding(.horizontal, 20)
              .padding(.vertical, 10)
          }
          .padding()

        }

        HStack {
          Button {
            Task { @MainActor in
              switch appModel.immersiveSpaceState {
                case .open:
                  appModel.immersiveSpaceState = .inTransition
                  await dismissImmersiveSpace()
                case .closed:
                  if let index = selectedIndex, datasets.indices.contains(index) {
                    switch datasets[index].2 {
                      case .Local:
                        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                        appModel.activeDataset = documentsDirectory.appendingPathComponent((datasets[index].0)).relativePath
                        appModel.datasetSource = datasets[index].2
                        await openSpace()
                      case .Remote:
                        if !appSettings.progressiveLoading {
                          progress = 0.0
                          statusText = "Initializing..."
                          continueExecution = true
                          wasCancelled = false
                          showDialog = true
                          startWork(activeDataset: datasets[index].0)
                        } else {
                          appModel.activeDataset = datasets[index].0
                          appModel.datasetSource = datasets[index].2
                          await openSpace()
                        }
                    }
                  }

                case .inTransition:
                  break
              }
            }
          } label: {
            Text(appModel.immersiveSpaceState == .open ? "Close Dataset" : "Open Dataset")
          }
          .disabled(selectedIndex == nil || appModel.immersiveSpaceState == .inTransition || isLoading)
          .animation(.none, value: 0)
          .fontWeight(.semibold)
          .buttonStyle(.borderedProminent)
          .padding()

          Button(action: {
            appModel.currentState = .importData
          }) {
            Text("Import Data")
          }

          Button("Refresh List") {
            Task { await loadDatasetFilesAsync() }
          }.padding()

          Button(action: {
            appModel.currentState = .start
          }) {
            Text("Back to Main Menu")
          }
          .padding()
        }
        .onAppear {
          Task { await loadDatasetFilesAsync() }
        }
      }.sheet(isPresented: $showDialog) {
        PrefetchDialog(
          isPresented: $showDialog,
          progress: $progress,
          statusText: $statusText,
          continueExecution: $continueExecution,
          wasCancelled: $wasCancelled
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
    }.onAppear() {
      appModel.immersiveSpaceState = .closed
    }
  }

  private func openSpace() async {
    appModel.immersiveSpaceState = .inTransition
    switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
      case .opened:
        appModel.currentState = .renderData
      case .userCancelled, .error:
        fallthrough
      @unknown default:
        appModel.immersiveSpaceState = .closed
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
    let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let inputFile = documentsDirectory
      .appendingPathComponent((datasets[index].0)).relativePath
    let fileURL = URL(fileURLWithPath: inputFile)

    do {
      try FileManager.default.removeItem(at: fileURL)
      datasets.remove(at: index)
    } catch {
      appModel.logger.error("Error deleting file: \(error)")
    }

    if let selected = selectedIndex, datasets.indices.contains(selected) == false {
      selectedIndex = nil
    }
  }

  private func openLoggerView() {
    dismissWindow(id: "LoggerView")
    openWindow(id: "LoggerView")
  }

  private func loadRemoteDatasets() async -> [AppModel.DatasetEntry] {
    var datasets: [AppModel.DatasetEntry] = []

    if !appSettings.serverAddress.isEmpty {
      await MainActor.run { loadingStage = .connectingServer }
      do {
        let manager = BORGVRRemoteDataManager(
          host: appSettings.serverAddress,
          port: UInt16(appSettings.serverPort),
          logger: appModel.logger
        )
        try manager.connect(timeout: appSettings.timeout)
        let remoteDatasets = try manager.requestDatasetList()
        for dataset in remoteDatasets {
          datasets.append((
            String(dataset.id),
            dataset.description,
            .Remote
          ))
        }
      } catch {
        appModel.logger.error("Error loading connecting to remote server: \(error.localizedDescription)")
      }
    }
    return datasets
  }


  func startWork(activeDataset:String) {
    DispatchQueue.global(qos: .userInitiated).async {

      let logger : GUILogger = GUILogger()
      logger.setProgressBinding($statusText, $progress)
      logger.setMinimumLogLevel(.dev)

      do{

        let manager = BORGVRRemoteDataManager(
          host: appSettings.serverAddress,
          port: UInt16(appSettings.serverPort),
          logger:logger
        )
        try manager.connect(timeout: appSettings.timeout)

        if let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {

          let fileURL = documentsURL.appendingPathComponent(
            "\(appSettings.serverAddress)-\(activeDataset).data"
          )

          let dataset = try manager.openDataset(
            datasetID: Int(activeDataset)!,
            timeout: appSettings.timeout,
            localCacheFilename: appSettings.makeLocalCopy ? fileURL.path : nil,
            asyncGet: true
          )


          DispatchQueue.main.async {
            if let localFile = dataset.localFile {
              appModel.datasetSource = .Local
              appModel.activeDataset = localFile
            }
          }

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
            statusText = "Loading \(count) bricks ..."
          }
          while dataset.localRatio < 1.0 {
            if !continueExecution { break }
            DispatchQueue.main.async {
              progress = dataset.localRatio
              statusText = "Loading bricks \(Int(dataset.localRatio * Double(count))) of \(count) \n\(String(format: "%.2f", dataset.localRatio * 100)) % complete..."
            }
            Thread.sleep(forTimeInterval: 1)
          }


        }
      } catch {
      }

      DispatchQueue.main.async {
        showDialog = false

      }

      if continueExecution {
        Task { @MainActor in
          await openSpace()
        }
      }
    }
  }

  private func loadLocalDataset() async -> [AppModel.DatasetEntry] {
    var datasets: [AppModel.DatasetEntry] = []

    let fileManager = FileManager.default
    if let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
      do {
        let files = try fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)
        let datasetURLs = files.filter { $0.pathExtension == "data" }
        for (index, url) in datasetURLs.enumerated() {
          await MainActor.run {
            loadingStage = .loadingLocalDataset(url.lastPathComponent, index, datasetURLs.count)
          }
          try? await Task.sleep(nanoseconds: 10_000_000)
          let data = try? BORGVRFileData(filename: url.path())
          if let data = data {
            datasets.append((
              url.lastPathComponent,
              data.getMetadata().datasetDescription,
              .Local
            ))
          }
        }
      } catch {
        appModel.logger.error("Error loading dataset files: \(error.localizedDescription)")
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

    var loadedDatasets: [AppModel.DatasetEntry] = await loadLocalDataset()
    loadedDatasets.append(contentsOf: await loadRemoteDatasets())

    await MainActor.run {
      datasets = loadedDatasets.sorted { $0.1 < $1.1 }
      isLoading = false
      loadingStage = .idle
    }
  }
}
