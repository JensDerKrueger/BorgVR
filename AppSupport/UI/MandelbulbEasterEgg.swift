import SwiftUI

@MainActor
private final class MandelbulbEasterEggModel: ObservableObject {
  enum Dialog { case invitation, size, explanation, progress, failure }
  @Published var isPresented = false
  @Published var dialog = Dialog.invitation
  @Published var size = MandelbulbEasterEggSize.small
  @Published var phase = MandelbulbEasterEggGenerator.Phase.generating
  @Published var progress = 0.0
  @Published var progressMessage = ""
  @Published var cancellationRequested = false
  @Published var errorMessage = ""
  private var trigger = MandelbulbEasterEggTrigger()
  private var cancellation: BorgVRVolumeConversionCancellationToken?
  var completedURL: URL?

  func tap() {
    guard !isPresented, trigger.tap(at: ProcessInfo.processInfo.systemUptime) else { return }
    dialog = .invitation
    isPresented = true
  }

  func explain() {
    guard !isPresented else { return }
    trigger = MandelbulbEasterEggTrigger()
    dialog = .explanation
    isPresented = true
  }

  func fail(_ error: Error) {
    errorMessage = error.localizedDescription
    dialog = .failure
    isPresented = true
  }

  func cancel() {
    cancellationRequested = true
    cancellation?.cancel()
  }

  func generate(directory: URL, logger: GUILogger,
                onFinished: @escaping @MainActor () -> Void = {}) {
    let token = BorgVRVolumeConversionCancellationToken()
    cancellation = token
    cancellationRequested = false
    phase = .generating
    progress = 0
    progressMessage = ""
    completedURL = nil
    dialog = .progress
    let resolution = size.rawValue
    let receiver = self
    Task {
      defer { onFinished() }
      do {
        let url = try await Task.detached(priority: .userInitiated) {
          try MandelbulbEasterEggGenerator.generate(resolution: resolution, directory: directory,
            logger: logger, cancellationToken: token) { phase, message, value in
              Task { @MainActor in
                receiver.phase = phase
                receiver.progressMessage = message
                receiver.progress = value
              }
            }
        }.value
        try token.checkCancellation()
        completedURL = url
        isPresented = false
      } catch {
        if token.isCancelled || error is CancellationError {
          isPresented = false
        } else {
          logger.error(error.localizedDescription)
          fail(error)
        }
      }
      cancellation = nil
    }
  }
}

struct MandelbulbEasterEgg: ViewModifier {
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var model = MandelbulbEasterEggModel()
#if os(iOS)
  @EnvironmentObject private var settings: AppSettings
#else
  @EnvironmentObject private var settings: StoredAppModel
#endif
#if os(visionOS)
  @Environment(RuntimeAppModel.self) private var appModel
#else
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var sharePlay: SharePlayCoordinator
#endif

  func body(content: Content) -> some View {
    content
      .contentShape(Rectangle())
      .onTapGesture { model.tap() }
#if os(macOS)
      .help("mandelbulb_artwork_description")
#else
      .simultaneousGesture(LongPressGesture().onEnded { _ in model.explain() })
      .help("mandelbulb_artwork_description")
#endif
      .sheet(isPresented: $model.isPresented, onDismiss: openCompletedDataset) {
        dialog
          .interactiveDismissDisabled(model.dialog == .progress)
      }
      .onChange(of: scenePhase) { _, phase in
        if phase == .background, model.dialog == .progress { model.cancel() }
      }
      .onDisappear { model.cancel() }
  }

  private var dialog: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("Mandelbulb").font(.title2.bold())
      switch model.dialog {
        case .invitation:
          Text("mandelbulb_invitation").fixedSize(horizontal: false, vertical: true)
          HStack {
            Spacer()
            Button("mandelbulb_no", role: .cancel) { model.isPresented = false }
            Button("mandelbulb_yes") { model.dialog = .size }
              .keyboardShortcut(.defaultAction)
          }
        case .size:
          Text("mandelbulb_choose_size")
          Picker("mandelbulb_choose_size", selection: $model.size) {
            ForEach(MandelbulbEasterEggSize.allCases) { size in
              Text(verbatim: size.title).tag(size)
            }
          }
          .pickerStyle(.segmented)
          .controlSize(.small)
          .labelsHidden()
          Text(verbatim: "\(model.size.rawValue) × \(model.size.rawValue) × \(model.size.rawValue)")
            .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
          Text(String(format: String(localized: "mandelbulb_space_required_format"),
            MandelbulbStorageRequirement.formatted(model.size.storage.requiredBytes),
            MandelbulbStorageRequirement.formatted(model.size.storage.compressedBytes)))
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          HStack {
            Spacer()
            Button("mandelbulb_cancel", role: .cancel) { model.isPresented = false }
            Button("mandelbulb_create", action: generate).keyboardShortcut(.defaultAction)
#if os(visionOS)
              .disabled(!appModel.canImportDataset)
#endif
          }
        case .explanation:
          Text("mandelbulb_artwork_description").fixedSize(horizontal: false, vertical: true)
          closeButton
        case .progress:
          if model.phase == .converting, !model.progressMessage.isEmpty {
            Text(verbatim: model.progressMessage)
              .fixedSize(horizontal: false, vertical: true)
          } else {
            Text(LocalizedStringKey(model.phase == .generating ? "mandelbulb_generating" : "mandelbulb_converting"))
          }
          ProgressView(value: model.progress)
          HStack {
            Spacer()
            Button("mandelbulb_cancel", role: .cancel) { model.cancel() }
              .disabled(model.cancellationRequested)
          }
        case .failure:
          Text(model.errorMessage).fixedSize(horizontal: false, vertical: true)
          closeButton
      }
    }
    .padding(28)
    .frame(idealWidth: 420)
  }

  private var closeButton: some View {
    HStack {
      Spacer()
      Button("mandelbulb_close", role: .cancel) { model.isPresented = false }
    }
  }

  private func generate() {
#if os(macOS)
    let directory = settings.resolvedDataDirectoryURL()
#else
    let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
#endif
#if os(visionOS)
    do {
      let workID = try appModel.beginImportWork()
      model.generate(directory: directory, logger: appModel.logger) {
        appModel.finishImportWork(workID)
      }
    } catch { model.fail(error) }
#else
    model.generate(directory: directory, logger: appModel.logger)
#endif
  }

  private func openCompletedDataset() {
    guard let url = model.completedURL else { return }
    model.completedURL = nil
    Task { @MainActor in
      do {
#if os(visionOS)
        let preparation = try appModel.beginDatasetOpeningPreparation()
        defer { appModel.finishDatasetOpeningPreparation(preparation) }
        guard appModel.rendererIsIdle else { throw VisionDatasetActivityGate.BusyError.renderer }
#endif
        let access = url.deletingLastPathComponent().startAccessingSecurityScopedResource()
        defer { if access { url.deletingLastPathComponent().stopAccessingSecurityScopedResource() } }
        let metadata = try BORGVRMetaData(url: url)
        try await appModel.volumeBrush.prepareOpening(datasetID: metadata.uniqueID, datasetURL: url)
#if os(visionOS)
        appModel.startImmersiveSpace(identifier: url.path, description: metadata.datasetDescription,
          source: .local, uniqueId: metadata.uniqueID,
          asGroupSessionHost: appModel.sharePlaySessionIsActive ? appModel.groupSessionHost : true)
#else
        appModel.openDataset(AppModel.DatasetEntry(identifier: url.path,
          description: metadata.datasetDescription, source: .local, uniqueId: metadata.uniqueID,
          metadataSummary: metadata.borgvrSummaryText),
          asGroupSessionHost: sharePlay.isInSession ? nil : true)
        sharePlay.datasetOpened()
#endif
      } catch { model.fail(error) }
    }
  }
}
