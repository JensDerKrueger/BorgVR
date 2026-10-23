import SwiftUI

struct OpenDatasetView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var appSettings: AppSettings
  @EnvironmentObject private var sharePlay: SharePlayCoordinator
#if os(macOS)
  @EnvironmentObject private var storedAppModel: StoredAppModel
#endif

  @StateObject private var workflow = DatasetOpenWorkflow()
  @State private var showDeleteConfirmation = false
  @State private var pendingDeleteKey: String?

  var body: some View {
    NavigationStack {
      Group {
        if workflow.isLoading && workflow.datasets.isEmpty {
          loadingPanel
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if workflow.datasets.isEmpty {
          ContentUnavailableView(
            "No datasets found",
            systemImage: "externaldrive.badge.questionmark",
            description: Text(emptyDatasetDescription)
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(workflow.datasets, id: \.selectionKey) { dataset in
                datasetRow(dataset)
                if dataset.selectionKey != workflow.datasets.last?.selectionKey {
                  Divider().padding(.leading, 52)
                }
              }
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .padding()
          }
          .background(datasetListBackground)
        }
      }
      .overlay {
        if workflow.isOpening || (workflow.isLoading && !workflow.datasets.isEmpty) {
          loadingPanel
            .padding(22)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
      }
      .navigationTitle("Open dataset")
      .toolbar { datasetToolbar }
      .alert(
        "Dataset could not be opened",
        isPresented: Binding(
          get: { workflow.openErrorMessage != nil },
          set: { if !$0 { workflow.openErrorMessage = nil } }
        )
      ) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(workflow.openErrorMessage ?? "")
      }
      .confirmationDialog("Delete dataset?", isPresented: $showDeleteConfirmation) {
        Button("Delete", role: .destructive) {
          if let pendingDeleteKey {
            workflow.deleteDataset(
              withKey: pendingDeleteKey,
              storage: storage,
              logger: appModel.logger
            )
          }
        }
      }
      .task { await refresh() }
      .onChange(of: appSettings.hideBuiltInDatasets) { _, _ in
        Task { await refresh() }
      }
    }
  }

  @ToolbarContentBuilder
  private var datasetToolbar: some ToolbarContent {
#if os(macOS)
    ToolbarItem(placement: .cancellationAction) {
      Button("Back") { appModel.navigationState = .start }
        .help("dataset_open_back_help")
    }
    ToolbarItemGroup(placement: .primaryAction) {
      refreshButton
      importButton
    }
    ToolbarItem(placement: .confirmationAction) { openButton }
#else
    ToolbarItem(placement: .topBarLeading) {
      Button {
        appModel.navigationState = .start
      } label: {
        Label("Back", systemImage: "chevron.backward")
      }
      .help("dataset_open_back_help")
    }
    ToolbarItemGroup(placement: .topBarTrailing) {
      refreshButton
      importButton
    }
    ToolbarItem(placement: .bottomBar) { openButton }
#endif
  }

  private var refreshButton: some View {
    Button { Task { await refresh() } } label: {
      Label("Refresh", systemImage: "arrow.clockwise")
    }
    .help("dataset_open_refresh_help")
  }

  private var importButton: some View {
    Button { appModel.navigationState = .importData } label: {
      Label("Import", systemImage: "square.and.arrow.down")
    }
    .help("dataset_open_import_help")
  }

  private var openButton: some View {
    Button { startOpeningSelectedDataset() } label: {
      Label("Open", systemImage: "play.fill")
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(.borderedProminent)
    .disabled(workflow.selectedDataset == nil || workflow.isLoading || workflow.isOpening)
    .help("dataset_open_open_help")
  }

  private var loadingPanel: some View {
    VStack(spacing: 14) {
      if let progress = workflow.openProgress {
        ProgressView(value: progress)
      } else {
        ProgressView()
      }
      Text(workflow.statusText)
        .foregroundStyle(.secondary)
      if workflow.openProgress != nil {
        Button("Stop now and continue later") { workflow.cancelOpening() }
          .buttonStyle(.bordered)
          .help("dataset_open_stop_download_help")
      }
    }
  }

  private func datasetRow(_ dataset: AppModel.DatasetEntry) -> some View {
    HStack(spacing: 12) {
      Button {
        workflow.selectedDatasetKey = dataset.selectionKey
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
      .simultaneousGesture(TapGesture(count: 2).onEnded { startOpening(dataset) })
      .help("dataset_open_select_help")

      if dataset.source == .local {
        Button(role: .destructive) {
          pendingDeleteKey = dataset.selectionKey
          showDeleteConfirmation = true
        } label: {
          Image(systemName: "trash")
        }
        .accessibilityLabel("Delete dataset")
        .help("Delete dataset")
        .buttonStyle(.borderless)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(isSelected(dataset) ? Color.accentColor.opacity(0.12) : Color.clear)
  }

  private func startOpeningSelectedDataset() {
    guard let dataset = workflow.selectedDataset else { return }
    startOpening(dataset)
  }

  private func startOpening(_ dataset: AppModel.DatasetEntry) {
    workflow.startOpening(
      dataset,
      appModel: appModel,
      appSettings: appSettings,
      sharePlay: sharePlay,
      storage: storage
    )
  }

  private func refresh() async {
    await workflow.loadDatasetFiles(
      appSettings: appSettings,
      storage: storage,
      logger: appModel.logger
    )
  }

  private func isSelected(_ dataset: AppModel.DatasetEntry) -> Bool {
    workflow.selectedDatasetKey == dataset.selectionKey
  }

  private func icon(for source: AppModel.DatasetSource) -> String {
    switch source {
      case .local, .builtIn: return "internaldrive"
      case .remote: return "network"
    }
  }

  private func subtitle(for dataset: AppModel.DatasetEntry) -> String {
    if let metadataSummary = dataset.metadataSummary {
      return metadataSummary
    }
    switch dataset.source {
      case .local: return String(localized: "Local")
      case let .remote(address, port, _): return "Remote - \(address):\(port)"
      case .builtIn: return String(localized: "built in")
    }
  }

  private var storage: DatasetStorageAccess {
#if os(macOS)
    DatasetStorageAccess(
      directoryURL: storedAppModel.resolvedDataDirectoryURL(),
      beginAccess: { storedAppModel.startAccessingDataDirectory() },
      endAccess: { storedAppModel.stopAccessingDataDirectory($0) },
      accessError: { storedAppModel.lastDataDirectoryAccessError }
    )
#else
    DatasetStorageAccess(
      directoryURL: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    )
#endif
  }

  private var datasetListBackground: Color {
#if os(macOS)
    Color(nsColor: .controlBackgroundColor)
#else
    Color(.systemGroupedBackground)
#endif
  }

  private var emptyDatasetDescription: String {
    let message = String(
      localized: "Built-in datasets are hidden. Import a dataset, configure a remote server, or show built-in datasets again in Settings."
    )
    if let accessMessage = workflow.dataDirectoryAccessMessage {
      return "\(accessMessage)\n\n\(message)"
    }
    return message
  }
}
