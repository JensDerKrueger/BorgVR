import AppKit
import SwiftUI
import UniformTypeIdentifiers
import simd

struct RenderView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var renderingParameters: RenderingParameters
  @EnvironmentObject var appSettings: AppSettings
  @EnvironmentObject private var storedAppModel: StoredAppModel
  @EnvironmentObject private var sharePlay: SharePlayCoordinator
  @EnvironmentObject private var session: ScreenBorgVRSession
  @EnvironmentObject private var docking: DockingController
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow

  @State private var transferSmoothCenter: Float = 0.25
  @State private var transferSmoothWidth: Float = 0.3
  @State private var restoredDetachedPanelWindows: Set<DockablePanelID> = []
  @State private var markerDragID: UUID?
  @State private var strokeDragID: UUID?
  @State private var brushPosition: SIMD3<Float>?
  @State private var sceneObjectDragID: UUID?
  @State private var measurementDragMeasurementID: UUID?
  @State private var measurementDragPointID: UUID?
  @State private var arcballStartLocation: CGPoint?
  @State private var arcballStartOrientation: simd_quatf?
  @State private var isExtractingIsoSurface = false
  @State private var isoSurfaceExtractionProgress = 0.0
  @State private var isoSurfaceExtractionCancellationRequested = false
  @State private var isoSurfaceExtractionToken: BorgVRIsoSurfaceExtractor.CancellationToken?
  @State private var isoSurfaceExtractionError: String?
  @State private var showLeaveSharePlayConfirmation = false
  @State private var pendingDatasetStateSave: DatasetStateSavePlan?
  @State private var showDatasetStateOverwriteConfirmation = false
  @State private var showNoDatasetStateToSave = false
  @State private var datasetStateSaveError: Error?
  @State private var showNoDatasetStateToRestore = false
  @State private var datasetStateRestoreError: Error?
  @State private var recordingSaveError: Error?
  @State private var recordingDatasetID: String?

  private let modelRotationSensitivity: Float = 0.006
  private let clippingSensitivity: Float = 0.0012
  private let clippingPinchSensitivity: Float = 0.45
  private let transferSmoothCenterSensitivity: Float = 0.003
  private let transferSmoothSlopeSensitivity: Float = 0.003
  private let dockedLightingPanelWidth: CGFloat = 340
  private let dockedMarkerPanelWidth: CGFloat = 380
  private let markerDepthScrollSensitivity: Float = 0.003

  var body: some View {
    ZStack(alignment: .top) {
      renderBackground
        .ignoresSafeArea()

      MacMetalView(
        onDragUpdate: applyInteractionDrag(update:),
        onDragEnded: finishInteractionGesture,
        onPointerDown: beginInteraction(update:),
        onMagnificationDelta: applyMagnificationDelta(_:),
        onMagnificationEnded: finishInteractionGesture,
        onDoubleClick: handleDoubleClick,
        onKeyboardShortcut: handleKeyboardShortcut(_:),
        onModifierFlagsChanged: updateVolumeBrushModifiers(_:),
        onPointerHover: updateVolumeBrushHover(_:),
        tracksPointerHover: appModel.interactionMode == .volumeEditing
      )
        .ignoresSafeArea()

      if docking.isDockedVisible(.renderControls) {
        RenderControlsPanel(isDetachedWindow: false)
          .padding()
      } else if !docking.isDetached(.renderControls) {
        HStack {
          Spacer()
          visibilityButton
        }
        .padding()
      }

      if docking.isDockedVisible(.isoEditor) && renderingParameters.renderMode == .isoValue {
        VStack {
          Spacer()

          DockableEditorPanel(panel: .isoEditor, maxWidth: 520) {
            IsovalueEditorView(usesPanelBackground: false) {
              docking.hide(.isoEditor)
            }
            .environmentObject(renderingParameters)
          }
          .padding(.leading, dockedEditorLeadingPadding)
          .padding(.trailing, dockedEditorTrailingPadding)
          .padding(.bottom)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }

      if docking.isDockedVisible(.transferFunctionEditor) && renderingParameters.renderMode != .isoValue {
        VStack {
          Spacer()

          DockableEditorPanel(panel: .transferFunctionEditor, maxWidth: 720) {
            TransferFunctionEditorView(
              usesPanelBackground: false,
              catalogDirectoryURLs: transferFunctionCatalogDirectoryURLs,
              onMutation: {
                session.commitExternalMutation(
                  source: .userInterface,
                  domain: .transferFunction
                )
              }
            ) {
              docking.hide(.transferFunctionEditor)
            }
            .environmentObject(renderingParameters)
          }
          .padding(.leading, dockedEditorLeadingPadding)
          .padding(.trailing, dockedEditorTrailingPadding)
          .padding(.bottom)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }

      measurementLabels

      if docking.isDockedVisible(.markerEditor) ||
         docking.isDockedVisible(.measurementEditor) ||
         docking.isDockedVisible(.lightingEditor) ||
         docking.isDockedVisible(.volumeBrushEditor) {
        HStack(alignment: .top, spacing: 16) {
          if docking.isDockedVisible(.lightingEditor) || docking.isDockedVisible(.volumeBrushEditor) {
            VStack(spacing: 16) {
              Spacer(minLength: 0)

              if docking.isDockedVisible(.lightingEditor) {
                DockableEditorPanel(panel: .lightingEditor) {
                  LightingEditorView(
                    renderMode: renderingParameters.renderMode,
                    lightDirection: $renderingParameters.lightDirection,
                    ambientLightColor: $renderingParameters.ambientLightColor,
                    diffuseLightColor: $renderingParameters.diffuseLightColor,
                    specularLightColor: $renderingParameters.specularLightColor,
                    usesPanelBackground: false,
                    showsTitle: false,
                    onChange: synchronizeState,
                    onCommit: sharePlay.flushSynchronization,
                    onClose: { docking.hide(.lightingEditor) }
                  )
                  .equatable()
                }
              }
              if docking.isDockedVisible(.volumeBrushEditor) {
                DockableEditorPanel(panel: .volumeBrushEditor) {
                  VolumeBrushControls(model: appModel.volumeBrush)
                }
              }
            }
            .frame(width: dockedLightingPanelWidth)
            .frame(maxHeight: .infinity)
            .transition(.move(edge: .leading).combined(with: .opacity))
          }

          Spacer(minLength: 0)

          HStack(spacing: 16) {
            if docking.isDockedVisible(.markerEditor) {
              DockableEditorPanel(panel: .markerEditor) {
                MacMarkerView()
              }
              .frame(width: dockedMarkerPanelWidth)
              .frame(maxHeight: .infinity)
              .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if docking.isDockedVisible(.measurementEditor) {
              DockableEditorPanel(panel: .measurementEditor) {
                MacMeasurementView()
              }
              .frame(width: dockedMarkerPanelWidth)
              .frame(maxHeight: .infinity)
              .transition(.move(edge: .trailing).combined(with: .opacity))
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, docking.isDockedVisible(.renderControls) ? 230 : 16)
        .padding(.horizontal)
        .padding(.bottom)
      }
    }
    .onAppear {
      docking.restoreForDatasetOpen()
      updateDetachedPanelWindows()
    }
    .onChange(of: renderingParameters.renderMode) {
      Task { @MainActor in
        await Task.yield()
        updateDetachedPanelWindows()
      }
    }
    .onChange(of: appSettings.showBrickVisualization) { _, isVisible in
      guard !isVisible, renderingParameters.brickVis else { return }
      renderingParameters.brickVis = false
      synchronizeState()
    }
    .onChange(of: appSettings.showLogButton) { _, isVisible in
      if !isVisible {
        docking.showsLog = false
      }
    }
    .onChange(of: docking.commandRequest) { _, request in
      guard let request else { return }
      handleCommand(request.command)
    }
    .sheet(isPresented: $docking.showsLog) {
      LoggerView(logger: appModel.logger)
    }
    .sheet(isPresented: $docking.showsDatasetInfo) {
      DatasetInfoView(
        dataset: appModel.activeDataset,
        metadata: appModel.activeDatasetMetadata
      ) {
        docking.showsDatasetInfo = false
      }
      .frame(minWidth: 420, minHeight: 360)
    }
    .sheet(isPresented: $isExtractingIsoSurface) {
      VStack(alignment: .leading, spacing: 18) {
        Text("Extracting Isosurface")
          .font(.headline)
        ProgressView(value: isoSurfaceExtractionProgress)
        Text(isoSurfaceExtractionProgress, format: .percent.precision(.fractionLength(0)))
          .foregroundStyle(.secondary)
          .monospacedDigit()
        HStack {
          Spacer()
          Button(isoSurfaceExtractionCancellationRequested ? "Cancelling..." : "Cancel") {
            isoSurfaceExtractionCancellationRequested = true
            isoSurfaceExtractionToken?.cancel()
          }
          .disabled(isoSurfaceExtractionCancellationRequested)
        }
      }
      .padding(24)
      .frame(width: 380)
      .interactiveDismissDisabled()
    }
    .alert("Isosurface Export Failed", isPresented: Binding(
      get: { isoSurfaceExtractionError != nil },
      set: { if !$0 { isoSurfaceExtractionError = nil } }
    )) {
      Button("OK") { isoSurfaceExtractionError = nil }
    } message: {
      Text(isoSurfaceExtractionError ?? "")
    }
    .alert("Leave SharePlay?", isPresented: $showLeaveSharePlayConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Leave SharePlay", role: .destructive) {
        closeDataset(leavingSharePlay: true)
      }
    } message: {
      Text("Closing this dataset will leave the current SharePlay session.")
    }
    .alert(
      "Overwrite Existing Files?",
      isPresented: $showDatasetStateOverwriteConfirmation
    ) {
      Button("Cancel", role: .cancel) { pendingDatasetStateSave = nil }
      Button("Overwrite") {
        if let plan = pendingDatasetStateSave { saveDatasetState(using: plan) }
      }
    } message: {
      Text("One or more files for this dataset already exist. Do you want to replace them?")
    }
    .alert("Nothing to Save", isPresented: $showNoDatasetStateToSave) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("There is no active transfer function and there are no objects or measurements to save.")
    }
    .alert(
      "Unable to Save Dataset State",
      isPresented: Binding(
        get: { datasetStateSaveError != nil },
        set: { if !$0 { datasetStateSaveError = nil } }
      )
    ) {
      Button("OK", role: .cancel) { datasetStateSaveError = nil }
    } message: {
      Text(datasetStateSaveError?.localizedDescription ?? "")
    }
    .alert("Nothing to Restore", isPresented: $showNoDatasetStateToRestore) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("No saved state is available for this dataset.")
    }
    .alert(
      "Unable to Restore Dataset State",
      isPresented: Binding(
        get: { datasetStateRestoreError != nil },
        set: { if !$0 { datasetStateRestoreError = nil } }
      )
    ) {
      Button("OK", role: .cancel) { datasetStateRestoreError = nil }
    } message: {
      Text(datasetStateRestoreError?.localizedDescription ?? "")
    }
    .alert(
      "Unable to Save Recording",
      isPresented: Binding(
        get: { recordingSaveError != nil },
        set: { if !$0 { recordingSaveError = nil } }
      )
    ) {
      Button("OK", role: .cancel) { recordingSaveError = nil }
    } message: {
      Text(recordingSaveError?.localizedDescription ?? "")
    }
  }

  @ViewBuilder
  private var renderBackground: some View {
    switch RenderBackgroundMode(rawValue: appSettings.renderBackgroundMode) ?? .system {
      case .system:
        Color(nsColor: .windowBackgroundColor)
      case .solid:
        appSettings.renderBackgroundPrimaryColor
      case .gradient:
        LinearGradient(
          colors: [
            appSettings.renderBackgroundPrimaryColor,
            appSettings.renderBackgroundSecondaryColor
          ],
          startPoint: .top,
          endPoint: .bottom
        )
    }
  }

  private var visibilityButton: some View {
    Button {
      docking.show(.renderControls)
    } label: {
      Image(systemName: "eye")
    }
    .accessibilityLabel("Show UI")
    .help(MacRenderShortcut.help("Show UI", shortcut: .toggleControls))
    .screenControlButtons()
  }

  private func handleCommand(_ command: MacCommand) {
    switch command {
      case .render(let shortcut):
        handleKeyboardShortcut(shortcut)
      case .closeDataset:
        requestDatasetClose()
      case .saveDatasetState:
        requestDatasetStateSave()
      case .restoreDatasetState:
        restoreDatasetState()
      case .startRecording:
        recordingDatasetID = appModel.activeDataset?.uniqueId
        session.startCommandRecording()
      case .stopRecording:
        stopRecordingAndSave()
    }
  }

  private func handleKeyboardShortcut(_ shortcut: MacRenderShortcut) {
    switch shortcut {
      case .translateLeft:
        translateModel(by: SIMD2<Float>(-0.02, 0))
      case .translateRight:
        translateModel(by: SIMD2<Float>(0.02, 0))
      case .translateUp:
        translateModel(by: SIMD2<Float>(0, 0.02))
      case .translateDown:
        translateModel(by: SIMD2<Float>(0, -0.02))
      case .erase, .restore:
        appModel.volumeBrush.mode = shortcut == .erase ? .erase : .restore
        applyInteractionModeSelection(.volumeEditing)
      case .smallerBrush, .largerBrush:
        appModel.volumeBrush.radius = min(0.15, max(0.002,
          appModel.volumeBrush.radius * (shortcut == .smallerBrush ? 0.8 : 1.25)))
      case .model:
        applyInteractionModeSelection(.model)
      case .clipping:
        applyInteractionModeSelection(.clipping)
      case .transferInteraction:
        applyInteractionModeSelection(.transferEditing)
      case .drawing:
        applyInteractionModeSelection(.drawing)
      case .placement:
        applyInteractionModeSelection(.objectPlacement)
      case .measurement:
        applyInteractionModeSelection(.measurement)
      case .volumeEditing:
        applyInteractionModeSelection(.volumeEditing)
      case .transferFunctionRendering:
        setRenderMode(.transferFunction1D)
      case .lightingRendering:
        setRenderMode(.transferFunction1DLighting)
      case .isoRendering:
        setRenderMode(.isoValue)
      case .screenshot:
        appModel.requestRenderScreenshot(to: nil, accessURL: nil) { result in
          if case let .failure(error) = result {
            appModel.logger.error(error.localizedDescription)
          }
        }
      case .extractIsosurface:
        presentIsoSurfaceSavePanel()
      case .reset:
        try? session.perform(.reset(.all), source: .userInterface)
        sharePlay.flushSynchronization()
      case .bricks:
        guard appSettings.showBrickVisualization else { return }
        renderingParameters.brickVis.toggle()
        session.commitExternalMutation(source: .userInterface, domain: .visualization)
        sharePlay.synchronize(kind: .stateOnly)
      case .synchronizeView:
        guard sharePlay.isInSession else { return }
        sharePlay.setScreenViewSynchronizationEnabled(!sharePlay.isScreenViewSynchronized)
      case .editor:
        togglePanel(renderingParameters.renderMode == .isoValue ? .isoEditor : .transferFunctionEditor)
      case .lighting:
        togglePanel(.lightingEditor)
      case .objects:
        togglePanel(.markerEditor)
      case .measurements:
        togglePanel(.measurementEditor)
      case .performance:
        openWindow(id: "PerformanceGraphView")
      case .log:
        guard appSettings.showLogButton else { return }
        docking.showsLog.toggle()
      case .datasetInfo:
        docking.showsDatasetInfo.toggle()
      case .docking:
        toggleRenderControlsDocking()
      case .toggleControls:
        toggleRenderControlsVisibility()
    }
  }

  private func presentIsoSurfaceSavePanel() {
    guard renderingParameters.renderMode == .isoValue,
          appModel.activeDataset != nil, appModel.volumeBrush.canExport else { return }
    guard appModel.isoSurfaceExtractionHandler != nil else {
      isoSurfaceExtractionError = String(localized: "The renderer is not ready for extraction.")
      return
    }

    let panel = NSSavePanel()
    panel.title = String(localized: "Extract Isosurface")
    panel.prompt = String(localized: "Export")
    panel.allowedContentTypes = [UTType(filenameExtension: "obj") ?? .data]
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    panel.directoryURL = storedAppModel.resolvedDataDirectoryURL()
    panel.nameFieldStringValue = suggestedIsoSurfaceFilename()

    let completion: (NSApplication.ModalResponse) -> Void = { response in
      guard response == .OK, let outputURL = panel.url else { return }
      startIsoSurfaceExtraction(to: outputURL)
    }
    if let window = NSApp.keyWindow {
      panel.beginSheetModal(for: window, completionHandler: completion)
    } else {
      panel.begin(completionHandler: completion)
    }
  }

  private func startIsoSurfaceExtraction(to outputURL: URL) {
    guard let handler = appModel.isoSurfaceExtractionHandler else {
      isoSurfaceExtractionError = String(localized: "The renderer is not ready for extraction.")
      return
    }
    let token = BorgVRIsoSurfaceExtractor.CancellationToken()
    let hasSecurityAccess = outputURL.startAccessingSecurityScopedResource()
    let normalizedIsoValue = Double(renderingParameters.isoValue)

    isoSurfaceExtractionToken = token
    isoSurfaceExtractionProgress = 0
    isoSurfaceExtractionCancellationRequested = false
    isExtractingIsoSurface = true

    handler(outputURL, normalizedIsoValue, token, { progress in
      DispatchQueue.main.async {
        isoSurfaceExtractionProgress = min(max(progress, 0), 1)
      }
    }, { result in
      DispatchQueue.main.async {
        if hasSecurityAccess {
          outputURL.stopAccessingSecurityScopedResource()
        }
        isExtractingIsoSurface = false
        isoSurfaceExtractionToken = nil
        isoSurfaceExtractionCancellationRequested = false
        switch result {
          case .success(let extraction):
            appModel.logger.info(
              String(
                format: String(localized: "Isosurface saved with %lld triangles: %@"),
                Int64(extraction.triangleCount),
                extraction.outputURL.path
              )
            )
          case .failure(let error):
            if error is CancellationError {
              appModel.logger.info(String(localized: "Isosurface extraction cancelled."))
            } else {
              isoSurfaceExtractionError = error.localizedDescription
              appModel.logger.error(error.localizedDescription)
            }
        }
      }
    })
  }

  private func suggestedIsoSurfaceFilename() -> String {
    let source = appModel.activeDataset?.description ?? "BorgVR"
    let invalidCharacters = CharacterSet.alphanumerics.inverted
    let stem = source.components(separatedBy: invalidCharacters)
      .filter { !$0.isEmpty }
      .joined(separator: "-")
    return "\(stem.isEmpty ? "BorgVR" : stem)-isosurface.obj"
  }

  private func requestDatasetClose() {
    if sharePlay.isInSession, !appModel.groupSessionHost {
      showLeaveSharePlayConfirmation = true
    } else {
      closeDataset(leavingSharePlay: false)
    }
  }

  private func closeDataset(leavingSharePlay: Bool) {
    if appSettings.autoloadTF,
       let fileURL = appModel.transferFunctionFileURL() {
      try? renderingParameters.saveDatasetTransferFunctions(to: fileURL)
    }
    appModel.saveAutomaticallyManagedDatasetState(
      appSettings: appSettings,
      renderingParameters: renderingParameters
    )
    if leavingSharePlay {
      sharePlay.leaveGroupActivity()
    } else {
      sharePlay.closeSharedDataset()
    }
    appModel.removeAllVolumeMarkers()
    appModel.replaceSceneMeshInstances([])
    appModel.removeAllVolumeMeasurements()
    docking.resetForDatasetClose()
    appModel.closeDataset(destination: .datasetSelection)
  }

  private func requestDatasetStateSave() {
    let plan = makeDatasetStateSavePlan()
    guard !plan.isEmpty else {
      showNoDatasetStateToSave = true
      return
    }
    pendingDatasetStateSave = plan
    if plan.hasExistingFiles {
      showDatasetStateOverwriteConfirmation = true
    } else {
      saveDatasetState(using: plan)
    }
  }

  private func makeDatasetStateSavePlan() -> DatasetStateSavePlan {
    let hasObjects = !appModel.volumeMarkers.isEmpty || !appModel.sceneMeshInstances.isEmpty
    let hasMeasurements = appModel.volumeMeasurements.contains { !$0.points.isEmpty }
    return DatasetStateSavePlan(
      transferFunctionURLs: renderingParameters.renderMode == .isoValue ? [] :
        appModel.transferFunctionFileURL().map {
          DatasetTransferFunctionStorage.fileURLs(baseURL: $0, componentCount: renderingParameters.componentCount)
        } ?? [],
      viewStateURL: appModel.viewStateFileURL(),
      objectURL: hasObjects ? appModel.objectFileURL() : nil,
      measurementURL: hasMeasurements ? appModel.measurementFileURL() : nil
    )
  }

  private func saveDatasetState(using plan: DatasetStateSavePlan) {
    defer { pendingDatasetStateSave = nil }
    guard let dataset = appModel.activeDataset else { return }
    do {
      if !plan.transferFunctionURLs.isEmpty {
        try renderingParameters.saveDatasetTransferFunctions(to: plan.transferFunctionURLs, description: dataset.description)
      }
      if let url = plan.viewStateURL {
        try DatasetStateStorage.saveViewState(
          renderingParameters.makeDatasetViewState(datasetID: dataset.uniqueId),
          to: url
        )
      }
      if let url = plan.objectURL {
        try DatasetStateStorage.saveObjects(
          datasetID: dataset.uniqueId,
          markers: appModel.volumeMarkers,
          meshInstances: appModel.sceneMeshInstances,
          to: url
        )
      }
      if let url = plan.measurementURL {
        try DatasetStateStorage.saveMeasurements(
          datasetID: dataset.uniqueId,
          measurements: appModel.volumeMeasurements,
          to: url
        )
      }
    } catch {
      datasetStateSaveError = error
    }
  }

  private func restoreDatasetState() {
    do {
      guard try appModel.restoreSavedDatasetState(
        renderingParameters: renderingParameters
      ) else {
        showNoDatasetStateToRestore = true
        return
      }
      session.commitExternalMutation(source: .userInterface, domain: .visualization)
      session.commitExternalMutation(source: .userInterface, domain: .objects)
      session.commitExternalMutation(source: .userInterface, domain: .measurements)
      sharePlay.synchronize(kind: .full)
      sharePlay.synchronizeMarkers()
      sharePlay.synchronizeMeasurements()
    } catch {
      datasetStateRestoreError = error
    }
  }

  private func stopRecordingAndSave() {
    _ = session.stopCommandRecording()
    let recordedInteractions = session.recordedGSCScript()
    var scriptSections: [String] = []
    if let recordingDatasetID {
      scriptSections.append("# Dataset\nopendataset \(gscQuote(recordingDatasetID))")
    }
    if !recordedInteractions.isEmpty {
      scriptSections.append("# Recorded interactions\n\(recordedInteractions)")
    }
    let script = scriptSections.joined(separator: "\n\n")
    recordingDatasetID = nil
    let panel = NSSavePanel()
    panel.title = String(localized: "Save Recording")
    panel.message = String(localized: "Save the recorded interactions as a GSC script.")
    panel.canCreateDirectories = true
    panel.allowedContentTypes = [UTType(filenameExtension: "gsc") ?? .plainText]
    panel.nameFieldStringValue = recordingFilename
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      Task { @MainActor in
        do {
          let output = script.isEmpty || script.hasSuffix("\n") ? script : script + "\n"
          try output.write(to: url, atomically: true, encoding: .utf8)
        } catch {
          recordingSaveError = error
        }
      }
    }
  }

  private var recordingFilename: String {
    let source = appModel.activeDataset?.description ?? String(localized: "BorgVR Recording")
    let invalidCharacters = CharacterSet(charactersIn: "/:")
      .union(.newlines)
      .union(.controlCharacters)
    let sanitized = source.components(separatedBy: invalidCharacters).joined(separator: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let basename = sanitized.isEmpty ? String(localized: "BorgVR Recording") : sanitized
    return basename + ".gsc"
  }

  private func setRenderMode(_ mode: RenderMode) {
    guard renderingParameters.renderMode != mode else { return }
    try? session.perform(.setRenderMode(mode), source: .userInterface)
  }

  private func togglePanel(_ panel: DockablePanelID) {
    if docking.isDetached(panel) {
      openWindow(id: panel.windowID)
    } else {
      docking.toggleVisibility(panel)
    }
  }

  private func toggleRenderControlsDocking() {
    if docking.isDetached(.renderControls) {
      docking.dock(.renderControls)
      dismissWindow(id: DockablePanelID.renderControls.windowID)
    } else {
      docking.detach(.renderControls)
      openWindow(id: DockablePanelID.renderControls.windowID)
    }
  }

  private func toggleRenderControlsVisibility() {
    if docking.isDetached(.renderControls) {
      if docking.isVisible(.renderControls) {
        docking.close(.renderControls)
        dismissWindow(id: DockablePanelID.renderControls.windowID)
      } else {
        docking.show(.renderControls)
      }
    } else {
      docking.toggleVisibility(.renderControls)
    }
  }

  private var transferFunctionCatalogDirectoryURLs: [URL] {
    [storedAppModel.resolvedDataDirectoryURL()]
  }

  private var dockedEditorLeadingPadding: CGFloat {
    docking.isDockedVisible(.lightingEditor) || docking.isDockedVisible(.volumeBrushEditor)
      ? dockedLightingPanelWidth + 32
      : 16
  }

  private var dockedEditorTrailingPadding: CGFloat {
    CGFloat(
      [DockablePanelID.markerEditor, .measurementEditor]
        .filter { docking.isDockedVisible($0) }.count
    ) * (dockedMarkerPanelWidth + 16) + 16
  }

  private func updateDetachedPanelWindows() {
    temporarilyCloseIncompatibleDetachedPanelWindows()
    restoreDetachedPanelWindows()
  }

  private func temporarilyCloseIncompatibleDetachedPanelWindows() {
    for panel in docking.detachedPanelsToTemporarilyClose(incompatibleWith: renderingParameters.renderMode) {
      docking.markDetachedWindowTemporarilyClosed(panel)
      dismissWindow(id: panel.windowID)
      restoredDetachedPanelWindows.remove(panel)
    }
  }

  private func restoreDetachedPanelWindows() {
    for panel in docking.detachedPanelsToRestore(compatibleWith: renderingParameters.renderMode) {
      guard !restoredDetachedPanelWindows.contains(panel) else { continue }
      openWindow(id: panel.windowID)
      restoredDetachedPanelWindows.insert(panel)
    }
  }

  private func handleDoubleClick() -> Bool {
    guard appModel.interactionMode == .measurement else { return false }
    if appModel.removeSelectedVolumeMeasurementPoint() {
      synchronizeMeasurements()
    }
    return true
  }

  private func applyInteractionModeSelection(_ mode: AppModel.InteractionMode) {
    DispatchQueue.main.async {
      guard appModel.interactionMode != mode else { return }
      if mode != .measurement {
        appModel.clearVolumeMeasurementSelection()
      }
      appModel.interactionMode = mode
      session.commitExternalMutation(source: .mouse, domain: .interaction)
    }
  }

  private func applyInteractionDrag(update: RenderDragUpdate) {
    switch appModel.interactionMode {
      case .volumeEditing:
        if update.isDirectPointer { applyVolumeBrush(update) }
        else if let position = brushPosition {
          brushPosition = appModel.markerDepthAdjustmentHandler?(position, Float(update.delta.height) * markerDepthScrollSensitivity)
          if let brushPosition {
            appModel.volumeBrush.context.showPreview(at: brushPosition, mode: volumeBrushMode(for: update.modifierFlags))
          }
        }
      case .model:
        if update.isDirectPointer {
          rotateModel(to: update.location, in: update.viewSize)
        } else {
          rotateModelIncrementally(by: update.delta)
        }
        synchronizeTransform()
      case .clipping:
        applyViewAlignedClipping(delta: update.delta)
        synchronizeState()
      case .transferEditing:
        applyTransferInteraction(update: update)
      case .drawing:
        if update.isDirectPointer {
          updateStrokeInteraction(update: update)
        }
      case .objectPlacement:
        if update.isDirectPointer {
          updateObjectInteraction(update: update)
        } else {
          moveSelectedMarkerInDepth(by: update.delta.height)
        }
      case .measurement:
        if update.isDirectPointer {
          updateMeasurementInteraction(update: update)
        } else {
          moveSelectedMeasurementPointInDepth(by: update.delta.height)
        }
    }
  }

  private func applyMagnificationDelta(_ delta: CGFloat) {
    guard delta > 0 else { return }
    if appModel.interactionMode == .volumeEditing {
      appModel.volumeBrush.radius = min(0.15, max(0.002, appModel.volumeBrush.radius * Double(delta)))
    } else if appModel.interactionMode == .clipping {
      applyDepthAlignedClipping(magnificationDelta: delta)
      synchronizeState()
    } else if appModel.interactionMode == .objectPlacement {
      scaleSelectedMarker(by: Float(delta))
    } else {
      renderingParameters.scale = min(
        ScreenInteractionLimits.modelScale.upperBound,
        max(
          ScreenInteractionLimits.modelScale.lowerBound,
          renderingParameters.scale * Float(delta)
        )
      )
      synchronizeTransform()
    }
  }

  private func finishInteractionGesture() {
    appModel.volumeBrush.context.finish(source: "pointer")
    arcballStartLocation = nil
    arcballStartOrientation = nil
    markerDragID = nil
    strokeDragID = nil
    appModel.endProjectedStrokeHandler?()
    sceneObjectDragID = nil
    measurementDragMeasurementID = nil
    measurementDragPointID = nil
    sharePlay.flushSynchronization()
  }

  private func beginInteraction(update: RenderDragUpdate) {
    switch appModel.interactionMode {
      case .volumeEditing:
        if appModel.volumeBrush.projectsOntoVolume { appModel.beginProjectedStrokeHandler?() }
        applyVolumeBrush(update)
      case .model:
        arcballStartLocation = update.location
        arcballStartOrientation = renderingParameters.orientation
      case .drawing:
        beginStrokeInteraction(update: update)
      case .objectPlacement:
        beginObjectInteraction(update: update)
      case .measurement:
        beginMeasurementInteraction(update: update)
      case .clipping, .transferEditing:
        break
    }
  }

  private func applyVolumeBrush(_ update: RenderDragUpdate) {
    guard let screenPosition = normalizedPosition(for: update),
          let position = interactionPosition(at: screenPosition, preservingDepthOf: brushPosition,
                                             projected: appModel.volumeBrush.projectsOntoVolume) else { return }
    brushPosition = position
    appModel.volumeBrush.context.apply(at: position, source: "pointer", mode: volumeBrushMode(for: update.modifierFlags))
  }

  private func updateVolumeBrushHover(_ update: RenderDragUpdate?) {
    guard appModel.interactionMode == .volumeEditing,
          let update, let screenPosition = normalizedPosition(for: update),
          let position = interactionPosition(at: screenPosition, preservingDepthOf: brushPosition,
                                             projected: appModel.volumeBrush.projectsOntoVolume) else {
      appModel.volumeBrush.context.finish(source: "pointer")
      return
    }
    if brushPosition != position { brushPosition = position }
    appModel.volumeBrush.context.showPreview(at: position, mode: volumeBrushMode(for: update.modifierFlags))
  }

  private func volumeBrushMode(for modifiers: NSEvent.ModifierFlags) -> BorgVRVolumeBrushMode {
    let selected = appModel.volumeBrush.mode
    return modifiers.contains(.shift) ? (selected == .erase ? .restore : .erase) : selected
  }

  private func updateVolumeBrushModifiers(_ modifiers: NSEvent.ModifierFlags) {
    guard appModel.interactionMode == .volumeEditing,
          let position = appModel.volumeBrush.context.previewPosition() else { return }
    appModel.volumeBrush.context.showPreview(at: position, mode: volumeBrushMode(for: modifiers))
  }

  private func beginObjectInteraction(update: RenderDragUpdate) {
    guard appModel.interactionMode == .objectPlacement,
          update.viewSize.width > 0,
          update.viewSize.height > 0 else { return }
    let screenPosition = SIMD2<Float>(
      Float(update.location.x / update.viewSize.width),
      Float(update.location.y / update.viewSize.height)
    )
    if let instanceID = appModel.sceneObjectHitTestHandler?(screenPosition) {
      appModel.clearVolumeMarkerSelection()
      appModel.selectedSceneMeshInstanceID = instanceID
      sceneObjectDragID = instanceID
      return
    }
    if let markerID = appModel.markerHitTestHandler?(screenPosition) {
      appModel.selectedSceneMeshInstanceID = nil
      appModel.selectedVolumeMarkerID = markerID
      markerDragID = markerID
      return
    }
    guard let position = interactionPosition(
      at: screenPosition,
      preservingDepthOf: nil,
      projected: appModel.projectObjectsOntoVolume
    ) else { return }
    switch appModel.validateSelectedSceneObjectPrototype() {
      case .sphere:
        guard let directionOrigin = appModel.markerDirectionOriginHandler?(screenPosition) else { return }
        let marker = VolumeMarker(
          id: UUID(),
          name: appModel.nextVolumeMarkerName(),
          position: position,
          radius: appModel.defaultVolumeMarkerRadius,
          color: appModel.defaultVolumeMarkerColor,
          directionOrigin: directionOrigin,
          showsDirection: appModel.defaultVolumeMarkerShowsDirection
        )
        appModel.volumeMarkers.append(marker)
        appModel.selectedSceneMeshInstanceID = nil
        appModel.selectedVolumeMarkerID = marker.id
        markerDragID = marker.id
      case .mesh(let assetID):
        guard let asset = appModel.sceneMeshAssets[assetID],
              let extent = appModel.activeDatasetMetadata?.physicalExtentMeters else { return }
        let instance = SceneMeshInstance(
          name: appModel.nextSceneMeshInstanceName(assetName: asset.name),
          asset: asset.reference,
          translationMeters: (position - SIMD3<Float>(repeating: 0.5)) * extent
        )
        appModel.sceneMeshInstances.append(instance)
        appModel.clearVolumeMarkerSelection()
        appModel.selectedSceneMeshInstanceID = instance.id
        sceneObjectDragID = instance.id
    }
    synchronizeMarkers()
  }

  private func updateObjectInteraction(update: RenderDragUpdate) {
    if markerDragID == nil && sceneObjectDragID == nil {
      beginObjectInteraction(update: update)
    }
    guard update.viewSize.width > 0, update.viewSize.height > 0 else { return }
    let screenPosition = SIMD2<Float>(
      Float(update.location.x / update.viewSize.width),
      Float(update.location.y / update.viewSize.height)
    )
    if let sceneObjectDragID,
       let index = appModel.sceneMeshInstances.firstIndex(where: { $0.id == sceneObjectDragID }),
       let extent = appModel.activeDatasetMetadata?.physicalExtentMeters {
      let safeExtent = simd_max(extent, SIMD3<Float>(repeating: 0.000_001))
      let currentPosition = appModel.sceneMeshInstances[index].translationMeters / safeExtent +
        SIMD3<Float>(repeating: 0.5)
      guard let position = interactionPosition(
        at: screenPosition,
        preservingDepthOf: currentPosition,
        projected: appModel.projectObjectsOntoVolume
      ) else { return }
      appModel.sceneMeshInstances[index].translationMeters =
        (position - SIMD3<Float>(repeating: 0.5)) * extent
      synchronizeMarkers()
      return
    }
    guard let markerDragID,
          let index = appModel.volumeMarkers.firstIndex(where: { $0.id == markerDragID }),
          appModel.volumeMarkers[index].kind == .sphere else { return }
    guard let position = interactionPosition(
      at: screenPosition,
      preservingDepthOf: appModel.volumeMarkers[index].position,
      projected: appModel.projectObjectsOntoVolume
    ) else { return }
    let offset = position - appModel.volumeMarkers[index].position
    for selectedIndex in appModel.volumeMarkers.indices
      where appModel.selectedVolumeMarkerIDs.contains(appModel.volumeMarkers[selectedIndex].id) {
      appModel.volumeMarkers[selectedIndex].translate(by: offset)
    }
    synchronizeMarkers()
  }

  private func beginStrokeInteraction(update: RenderDragUpdate) {
    guard appModel.interactionMode == .drawing,
          let screenPosition = normalizedPosition(for: update) else { return }
    if appModel.projectObjectsOntoVolume {
      appModel.beginProjectedStrokeHandler?()
    }
    guard let position = interactionPosition(
            at: screenPosition,
            preservingDepthOf: nil,
            projected: appModel.projectObjectsOntoVolume
          ) else {
      appModel.endProjectedStrokeHandler?()
      return
    }
    let stroke = VolumeMarker.stroke(
      name: appModel.nextVolumeMarkerName(for: .stroke),
      firstPoint: VolumeMarkerPoint(
        position: position,
        radius: VolumeMarkerRadius.strokeDefault
      ),
      color: appModel.defaultVolumeMarkerColor
    )
    appModel.volumeMarkers.append(stroke)
    appModel.selectedSceneMeshInstanceID = nil
    appModel.selectedVolumeMarkerID = stroke.id
    strokeDragID = stroke.id
    synchronizeMarkers()
  }

  private func updateStrokeInteraction(update: RenderDragUpdate) {
    if strokeDragID == nil { beginStrokeInteraction(update: update) }
    guard let strokeDragID,
          let index = appModel.volumeMarkers.firstIndex(where: { $0.id == strokeDragID }),
          let screenPosition = normalizedPosition(for: update),
          let position = interactionPosition(
            at: screenPosition,
            preservingDepthOf: appModel.volumeMarkers[index].points.last?.position,
            projected: appModel.projectObjectsOntoVolume
          ) else { return }
    let coordinateScale = appModel.activeDatasetMetadata.map {
      VolumeRenderResources.normalizedVolumeExtent(for: $0)
    } ?? .one
    if appModel.volumeMarkers[index].appendStrokePoint(
      VolumeMarkerPoint(position: position, radius: VolumeMarkerRadius.strokeDefault),
      coordinateScale: coordinateScale
    ) {
      synchronizeMarkers()
    }
  }

  private func scaleSelectedMarker(by factor: Float) {
    guard let markerID = appModel.selectedVolumeMarkerID,
          let index = appModel.volumeMarkers.firstIndex(where: { $0.id == markerID }) else { return }
    for selectedIndex in appModel.volumeMarkers.indices
      where appModel.selectedVolumeMarkerIDs.contains(appModel.volumeMarkers[selectedIndex].id) {
      appModel.volumeMarkers[selectedIndex].scaleRadii(by: factor)
    }
    if appModel.volumeMarkers[index].kind == .sphere {
      appModel.defaultVolumeMarkerRadius = appModel.volumeMarkers[index].radius
    }
    synchronizeMarkers()
  }

  private func moveSelectedMarkerInDepth(by scrollDelta: CGFloat) {
    guard scrollDelta != 0,
          let markerID = appModel.selectedVolumeMarkerID,
          let index = appModel.volumeMarkers.firstIndex(where: { $0.id == markerID }),
          let position = appModel.markerDepthAdjustmentHandler?(
            appModel.volumeMarkers[index].position,
            Float(scrollDelta) * markerDepthScrollSensitivity
          ) else { return }
    let offset = position - appModel.volumeMarkers[index].position
    for selectedIndex in appModel.volumeMarkers.indices
      where appModel.selectedVolumeMarkerIDs.contains(appModel.volumeMarkers[selectedIndex].id) {
      appModel.volumeMarkers[selectedIndex].translate(by: offset)
    }
    synchronizeMarkers()
  }

  private func normalizedPosition(for update: RenderDragUpdate) -> SIMD2<Float>? {
    guard update.viewSize.width > 0, update.viewSize.height > 0 else { return nil }
    return SIMD2<Float>(
      Float(update.location.x / update.viewSize.width),
      Float(update.location.y / update.viewSize.height)
    )
  }

  private func interactionPosition(
    at screenPosition: SIMD2<Float>,
    preservingDepthOf existingPosition: SIMD3<Float>?,
    projected: Bool
  ) -> SIMD3<Float>? {
    if projected,
       let position = appModel.projectedVolumePositionHandler?(
         screenPosition,
         existingPosition
       ) {
      return position
    }
    return appModel.markerPositionHandler?(screenPosition, existingPosition)
  }

  private func beginMeasurementInteraction(update: RenderDragUpdate) {
    guard let screenPosition = normalizedPosition(for: update) else { return }
    if let hit = appModel.measurementHitTestHandler?(screenPosition) {
      appModel.selectedVolumeMeasurementID = hit.measurementID
      appModel.selectedVolumeMeasurementPointID = hit.pointID
      measurementDragMeasurementID = hit.measurementID
      measurementDragPointID = hit.pointID
      if let measurement = appModel.volumeMeasurements.first(where: { $0.id == hit.measurementID }) {
        appModel.measurementKind = measurement.kind
      }
      return
    }
    guard let position = interactionPosition(
            at: screenPosition,
            preservingDepthOf: nil,
            projected: appModel.projectMeasurementsOntoVolume
          ),
          let extent = appModel.activeDatasetMetadata?.physicalExtentMeters else { return }
    var measurementID = appModel.selectedVolumeMeasurementID
    if measurementID.flatMap({ id in
      appModel.volumeMeasurements.first(where: { $0.id == id })?.kind
    }) != appModel.measurementKind {
      measurementID = appModel.volumeMeasurements.last(where: {
        $0.kind == appModel.measurementKind
      })?.id
    }
    if measurementID == nil { measurementID = appModel.createVolumeMeasurement() }
    guard let measurementID,
          let index = appModel.volumeMeasurements.firstIndex(where: { $0.id == measurementID }),
          let pointID = appModel.volumeMeasurements[index].addPoint(
            at: position,
            physicalExtent: extent
          ) else { return }
    appModel.selectedVolumeMeasurementID = measurementID
    appModel.selectedVolumeMeasurementPointID = pointID
    measurementDragMeasurementID = measurementID
    measurementDragPointID = pointID
    synchronizeMeasurements()
  }

  private func updateMeasurementInteraction(update: RenderDragUpdate) {
    if measurementDragPointID == nil { beginMeasurementInteraction(update: update) }
    guard let screenPosition = normalizedPosition(for: update),
          let measurementID = measurementDragMeasurementID,
          let pointID = measurementDragPointID,
          let index = appModel.volumeMeasurements.firstIndex(where: { $0.id == measurementID }),
          let point = appModel.volumeMeasurements[index].points.first(where: { $0.id == pointID }),
          let position = interactionPosition(
            at: screenPosition,
            preservingDepthOf: point.position,
            projected: appModel.projectMeasurementsOntoVolume
          ),
          let extent = appModel.activeDatasetMetadata?.physicalExtentMeters else { return }
    appModel.volumeMeasurements[index].setPoint(
      id: pointID,
      position: position,
      physicalExtent: extent
    )
    synchronizeMeasurements()
  }

  private func moveSelectedMeasurementPointInDepth(by delta: CGFloat) {
    guard delta != 0,
          let measurementID = appModel.selectedVolumeMeasurementID,
          let pointID = appModel.selectedVolumeMeasurementPointID,
          let index = appModel.volumeMeasurements.firstIndex(where: { $0.id == measurementID }),
          let point = appModel.volumeMeasurements[index].points.first(where: { $0.id == pointID }),
          let position = appModel.markerDepthAdjustmentHandler?(
            point.position,
            Float(delta) * markerDepthScrollSensitivity
          ),
          let extent = appModel.activeDatasetMetadata?.physicalExtentMeters else { return }
    appModel.volumeMeasurements[index].setPoint(
      id: pointID,
      position: position,
      physicalExtent: extent
    )
    synchronizeMeasurements()
  }

  private var measurementLabels: some View {
    GeometryReader { proxy in
      ForEach(appModel.measurementScreenLabels) { label in
        Text(label.text)
          .font(.caption2.monospacedDigit())
          .padding(.horizontal, 5)
          .padding(.vertical, 2)
          .foregroundStyle(.white)
          .background(
            Color(
              red: Double(label.color.x),
              green: Double(label.color.y),
              blue: Double(label.color.z)
            ).opacity(0.82),
            in: Capsule()
          )
          .position(
            x: CGFloat(label.position.x) * proxy.size.width,
            y: CGFloat(label.position.y) * proxy.size.height
          )
      }
    }
    .allowsHitTesting(false)
  }

  private func applyTransferInteraction(update: RenderDragUpdate) {
    if renderingParameters.renderMode == .isoValue {
      let transferDelta = Float(update.delta.width) * 0.0006
      renderingParameters.normIsoValue = min(1, max(0, renderingParameters.normIsoValue + transferDelta))
      synchronizeState()
      return
    }

    renderingParameters.objectWillChange.send()
    let parameters = transferSmoothParameters(for: update)
    transferSmoothCenter = parameters.center
    transferSmoothWidth = parameters.width
    renderingParameters.transferFunction.smoothStep(
      start: parameters.center - parameters.width * 0.5,
      shift: parameters.width,
      channels: [0, 1, 2, 3]
    )
    synchronizeFullState()
  }

  private func transferSmoothParameters(for update: RenderDragUpdate) -> (center: Float, width: Float) {
    guard update.viewSize.width > 0, update.viewSize.height > 0 else {
      return (transferSmoothCenter, transferSmoothWidth)
    }

    if update.isDirectPointer {
      let center = clamp(Float(update.location.x / update.viewSize.width))
      let steepness = clamp(Float(update.location.y / update.viewSize.height))
      let width = ScreenInteractionLimits.transferSmoothWidth.upperBound - steepness * (
        ScreenInteractionLimits.transferSmoothWidth.upperBound -
        ScreenInteractionLimits.transferSmoothWidth.lowerBound
      )
      return (center, width)
    }

    return (
      clamp(transferSmoothCenter + Float(update.delta.width) * transferSmoothCenterSensitivity),
      clamp(
        transferSmoothWidth - Float(update.delta.height) * transferSmoothSlopeSensitivity,
        ScreenInteractionLimits.transferSmoothWidth.lowerBound,
        ScreenInteractionLimits.transferSmoothWidth.upperBound
      )
    )
  }

  private func clamp(_ value: Float, _ lowerBound: Float = 0, _ upperBound: Float = 1) -> Float {
    min(upperBound, max(lowerBound, value))
  }

  private func rotateModel(to current: CGPoint, in viewSize: CGSize) {
    guard viewSize.width > 0,
          viewSize.height > 0,
          let start = arcballStartLocation,
          let startOrientation = arcballStartOrientation else { return }

    let startVector = arcballVector(at: start, in: viewSize)
    let currentVector = arcballVector(at: current, in: viewSize)
    let rotation = quaternionRotating(from: startVector, to: currentVector)
    renderingParameters.orientation = simd_normalize(rotation * startOrientation)
  }

  private func arcballVector(at location: CGPoint, in viewSize: CGSize) -> SIMD3<Float> {
    let radius = Float(max(1, min(viewSize.width, viewSize.height) * 0.5))
    var vector = SIMD3<Float>(
      (Float(location.x) - Float(viewSize.width) * 0.5) / radius,
      (Float(location.y) - Float(viewSize.height) * 0.5) / radius,
      0
    )
    let distanceSquared = vector.x * vector.x + vector.y * vector.y
    if distanceSquared <= 1 {
      vector.z = sqrt(1 - distanceSquared)
      return vector
    }
    return simd_normalize(vector)
  }

  private func quaternionRotating(
    from start: SIMD3<Float>,
    to end: SIMD3<Float>
  ) -> simd_quatf {
    let cosine = min(1, max(-1, simd_dot(start, end)))
    if cosine < -0.9999 {
      let reference = abs(start.x) < 0.9
        ? SIMD3<Float>(1, 0, 0)
        : SIMD3<Float>(0, 1, 0)
      return simd_quatf(angle: .pi, axis: simd_normalize(simd_cross(start, reference)))
    }

    let axis = simd_cross(start, end)
    return simd_normalize(
      simd_quatf(ix: axis.x, iy: axis.y, iz: axis.z, r: 1 + cosine)
    )
  }

  private func rotateModelIncrementally(by delta: CGSize) {
    let xAngle = Float(delta.height) * modelRotationSensitivity
    let yAngle = Float(delta.width) * modelRotationSensitivity
    guard xAngle != 0 || yAngle != 0 else { return }

    let xRotation = simd_quatf(angle: xAngle, axis: SIMD3<Float>(1, 0, 0))
    let yRotation = simd_quatf(angle: yAngle, axis: SIMD3<Float>(0, 1, 0))
    renderingParameters.orientation = simd_normalize(yRotation * xRotation * renderingParameters.orientation)
  }

  private func applyViewAlignedClipping(delta: CGSize) {
    let axes = rotatedVolumeAxes()
    let horizontalAxis = bestProjectedAxis(axes, component: 0)
    let verticalAxis = bestProjectedAxis(axes, component: 1, excluding: horizontalAxis)

    if abs(delta.width) > 0 {
      let axisDirection = axes[horizontalAxis].x >= 0 ? Float(1) : Float(-1)
      updateClipping(axis: horizontalAxis, delta: Float(delta.width) * axisDirection * clippingSensitivity)
    }

    if abs(delta.height) > 0 {
      let axisDirection = axes[verticalAxis].y >= 0 ? Float(1) : Float(-1)
      updateClipping(axis: verticalAxis, delta: -Float(delta.height) * axisDirection * clippingSensitivity)
    }
  }

  private func applyDepthAlignedClipping(magnificationDelta: CGFloat) {
    let axes = rotatedVolumeAxes()
    let horizontalAxis = bestProjectedAxis(axes, component: 0)
    let verticalAxis = bestProjectedAxis(axes, component: 1, excluding: horizontalAxis)
    let depthAxis = axes.indices.first { $0 != horizontalAxis && $0 != verticalAxis } ?? bestProjectedAxis(axes, component: 2)
    let axisDirection = axes[depthAxis].z >= 0 ? Float(1) : Float(-1)
    let delta = -Float(log(Double(magnificationDelta))) * axisDirection * clippingPinchSensitivity
    updateClipping(axis: depthAxis, delta: delta)
  }

  private func rotatedVolumeAxes() -> [SIMD3<Float>] {
    let rotation = simd_float4x4(renderingParameters.orientation)
    let localAxes = [
      SIMD4<Float>(1, 0, 0, 0),
      SIMD4<Float>(0, 1, 0, 0),
      SIMD4<Float>(0, 0, 1, 0)
    ]

    return localAxes.map { axis in
      let projected = rotation * axis
      return SIMD3<Float>(projected.x, projected.y, projected.z)
    }
  }

  private func bestProjectedAxis(_ axes: [SIMD3<Float>], component: Int, excluding excludedAxis: Int? = nil) -> Int {
    var bestAxis = 0
    var bestAlignment: Float = -1

    for axis in axes.indices where axis != excludedAxis {
      let alignment = abs(axes[axis][component])
      if alignment > bestAlignment {
        bestAlignment = alignment
        bestAxis = axis
      }
    }

    return bestAxis
  }

  private func updateClipping(axis: Int, delta: Float) {
    renderingParameters.clippingTranslation[axis] = min(0.98, max(-0.98, renderingParameters.clippingTranslation[axis] + delta))
    let translation = renderingParameters.clippingTranslation[axis]

    if translation >= 0 {
      renderingParameters.clipMin[axis] = translation
      renderingParameters.clipMax[axis] = 1
    } else {
      renderingParameters.clipMin[axis] = 0
      renderingParameters.clipMax[axis] = 1 + translation
    }
  }

  private func translateModel(by offset: SIMD2<Float>) {
    var transform = session.currentSnapshot().transform
    transform.translation += SIMD3<Float>(offset.x, offset.y, 0)
    try? session.perform(.setTransform(transform), source: .userInterface)
    sharePlay.flushSynchronization()
  }

  private func synchronizeTransform() {
    session.commitExternalMutation(source: .mouse, domain: .visualization)
    sharePlay.synchronize(kind: .transformOnly)
  }

  private func synchronizeState() {
    session.commitExternalMutation(source: .mouse, domain: .visualization)
    sharePlay.synchronize(kind: .stateOnly)
  }

  private func synchronizeFullState() {
    session.commitExternalMutation(source: .mouse, domain: .transferFunction)
    sharePlay.synchronize(kind: .full)
  }

  private func synchronizeMarkers() {
    session.commitExternalMutation(source: .mouse, domain: .objects)
    sharePlay.synchronizeMarkers()
  }

  private func synchronizeMeasurements() {
    session.commitExternalMutation(source: .mouse, domain: .measurements)
    sharePlay.synchronizeMeasurements()
  }
}
