import SwiftUI

private struct DatasetStateActionButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.headline)
      .foregroundStyle(.teal)
      .padding(.horizontal, 14)
      .frame(minWidth: 106, minHeight: 46)
      .contentShape(Rectangle())
      .background(
        Color.teal.opacity(configuration.isPressed ? 0.22 : 0.13),
        in: RoundedRectangle(cornerRadius: 10)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10)
          .stroke(Color.teal.opacity(0.25), lineWidth: 1)
      )
      .opacity(configuration.isPressed ? 0.7 : 1)
  }
}

/**
 A SwiftUI view exposing high-level render options for BorgVR.

 This view lets the user:

 - Select the active render mode (1D transfer function with/without
 lighting, or isovalue rendering).
 - Select the interaction mode and open its associated tools.
 - Optionally open profiling tools.
 - Close the currently active dataset (immersive space).

 It also cleans up auxiliary windows plus voice input when the view
 disappears or the scene goes into the background.
 */
struct RenderView: View {
  /// Global runtime application model (window state, immersion state, etc.).
  @Environment(RuntimeAppModel.self) private var runtimeAppModel

  /// Shared rendering parameters (current render mode, transfer function, …).
  @Environment(SharedAppModel.self) private var sharedAppModel

  /// Persistent user settings and profiling options.
  @EnvironmentObject var storedAppModel: StoredAppModel
  @EnvironmentObject private var serverController: BackgroundServerController

  /// Scene phase, used to close the dataset when the app goes to background.
  @Environment(\.scenePhase) private var scenePhase

  /// Dismisses the immersive space when requested.
  @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

  /// Opens auxiliary windows (editors, profiling, etc.).
  @Environment(\.openWindow) private var openWindow

  /// Dismisses auxiliary windows by identifier.
  @Environment(\.dismissWindow) private var dismissWindow

  /// Voice recognition service shared across views.
  @EnvironmentObject var voice: VoiceCommandService

  /// Text-to-speech helper used for voice feedback.
  @EnvironmentObject var speech: SpeechHelper

  @State private var copiedWebGPUShareLink = false
  @State private var showLeaveSharePlayConfirmation = false
  @State private var pendingDatasetStateSave: DatasetStateSavePlan?
  @State private var showDatasetStateOverwriteConfirmation = false
  @State private var showNoDatasetStateToSave = false
  @State private var datasetStateSaveError: Error?
  @State private var showNoDatasetStateToRestore = false
  @State private var datasetStateRestoreError: Error?

  var body: some View {
    VStack(spacing: 20) {
      Text("render_title")
        .font(.title)
        .bold()

      VStack(spacing: 6) {
        Text("render_picker_title")
          .font(.headline)
          .bold()

        Picker(
          "render_picker_title",
          selection: Binding(
            get: { sharedAppModel.renderMode },
            set: { newValue in
              sharedAppModel.renderMode = newValue
              sharedAppModel.synchronize(kind: .stateOnly)
            }
          )
        ) {
          Text("renderMode_transferFunction1D")
            .tag(RenderMode.transferFunction1D)
          Text("renderMode_transferFunction1DLighting")
            .tag(RenderMode.transferFunction1DLighting)
          Text("renderMode_isoValue")
            .tag(RenderMode.isoValue)
        }
        .pickerStyle(.segmented)
      }
      .padding(.horizontal)

      HandInteractionControlsView()

      Spacer()

      HStack {
        HStack(spacing: 8) {
          Button(action: requestDatasetStateSave) {
            Label("dataset_state_save_short", systemImage: "tray.and.arrow.down")
          }
          .accessibilityLabel("Save Dataset State")
          .help("Save Dataset State")
          .buttonStyle(DatasetStateActionButtonStyle())

          Button(action: restoreDatasetState) {
            Label("dataset_state_load_short", systemImage: "tray.and.arrow.up")
          }
          .accessibilityLabel("Restore Dataset State")
          .help("Restore Dataset State")
          .buttonStyle(DatasetStateActionButtonStyle())
        }
        .padding()

        if storedAppModel.showProfiling {
          Button(action: openProfileView) {
            Text("render_button_profiling")
              .font(.headline)
              .padding(.horizontal, 20)
              .padding(.vertical, 10)
          }
          .padding()
        }

        ShareLink(
          item: BorgVRActivity(),
          preview: SharePreview(
            NSLocalizedString(
              "render_share_preview_title",
              comment: "Title for live collaboration share preview"
            )
          )
        ) {
          Label("render_button_share", systemImage: "shareplay")
        }
        .simultaneousGesture(
          TapGesture().onEnded {
            sharedAppModel.markLocalActivityStarter()
          }
        )
        .padding()

        if canCopyWebGPUShareLink {
          Button(action: copyWebGPUShareLink) {
            Image(systemName: copiedWebGPUShareLink ? "checkmark" : "link")
              .font(.headline)
              .padding(.horizontal, 20)
              .padding(.vertical, 10)
          }
          .accessibilityLabel("Copy WebGPU link")
          .help("Copy WebGPU link")
          .padding()
        }

        Button(action: requestDatasetClose) {
          Text("render_button_close_dataset")
            .font(.headline)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .background(
          RoundedRectangle(cornerRadius: 30)
            .fill(Color.red)
        )
        .foregroundColor(.white)
        .padding()
      }
    }
    .onChange(of: scenePhase) { _, newPhase in
      Task { @MainActor in
        if newPhase == .background {
          closeDataset(
            leavingSharePlay: sharedAppModel.isInGroupSession
              && !runtimeAppModel.groupSessionHost
          )
        }
      }
    }
    .onChange(of: runtimeAppModel.auxiliaryWindowToggleRequest) { _, request in
      guard let request else { return }
      toggleAuxiliaryWindow(request)
    }
    .onDisappear {
      dismissWindow(id: "TransferFunctionEditorView")
      dismissWindow(id: "IsovalueEditorView")
      dismissWindow(id: "PerformanceGraphView")
      dismissWindow(id: "LoggerView")
      dismissWindow(id: "ProfileView")
      dismissWindow(id: "MarkerView")
      dismissWindow(id: "MeasurementView")
      dismissWindow(id: "LightingEditorView")
      dismissWindow(id: "VoiceCommandsView")
      voice.stopListening()
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
    .padding()
  }

  /// Opens the profiling options window if it is not already visible.
  private func openProfileView() {
    if !runtimeAppModel.isViewOpen("ProfileView") {
      openWindow(id: "ProfileView")
    }
  }

  private func toggleAuxiliaryWindow(
    _ request: RuntimeAppModel.AuxiliaryWindowToggleRequest
  ) {
    if runtimeAppModel.isViewOpen(request.windowID) {
      dismissWindow(id: request.windowID)
      return
    }
    if let otherWindowID = request.mutuallyExclusiveWindowID,
       runtimeAppModel.isViewOpen(otherWindowID) {
      dismissWindow(id: otherWindowID)
    }
    openWindow(id: request.windowID)
  }

  /**
   Initiates closing of the currently active dataset.

   This sets the immersive space intent to `.close`. The actual closing
   and teardown logic is handled elsewhere in the runtime model.
   */
  private func requestDatasetClose() {
    if sharedAppModel.isInGroupSession, !runtimeAppModel.groupSessionHost {
      showLeaveSharePlayConfirmation = true
    } else {
      closeDataset(leavingSharePlay: false)
    }
  }

  private func closeDataset(leavingSharePlay: Bool) {
    if leavingSharePlay {
      sharedAppModel.leaveGroupActivity()
    }
    runtimeAppModel.requestDatasetClose(destination: .datasetSelection)
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
    guard let dataset = runtimeAppModel.activeDataset else {
      return DatasetStateSavePlan(
        transferFunctionURL: nil,
        viewStateURL: nil,
        objectURL: nil,
        measurementURL: nil
      )
    }
    let documentsDirectory = FileManager.default.urls(
      for: .documentDirectory,
      in: .userDomainMask
    ).first
    let transferFunctionURL = documentsDirectory?
      .appendingPathComponent(dataset.uniqueId)
      .appendingPathExtension("tf1d")
    let hasObjects = !sharedAppModel.volumeMarkers.isEmpty ||
      !sharedAppModel.sceneMeshInstances.isEmpty
    let hasMeasurements = sharedAppModel.volumeMeasurementsSnapshot().contains {
      !$0.points.isEmpty
    }
    return DatasetStateSavePlan(
      transferFunctionURL: sharedAppModel.renderMode == .isoValue
        ? nil
        : transferFunctionURL,
      viewStateURL: DatasetStateStorage.viewStateFileURL(
        datasetID: dataset.uniqueId,
        logger: runtimeAppModel.logger
      ),
      objectURL: hasObjects
        ? DatasetStateStorage.objectFileURL(
          datasetID: dataset.uniqueId,
          logger: runtimeAppModel.logger
        )
        : nil,
      measurementURL: hasMeasurements
        ? DatasetStateStorage.measurementFileURL(
          datasetID: dataset.uniqueId,
          logger: runtimeAppModel.logger
        )
        : nil
    )
  }

  private func saveDatasetState(using plan: DatasetStateSavePlan) {
    defer { pendingDatasetStateSave = nil }
    guard let dataset = runtimeAppModel.activeDataset else { return }
    do {
      if let url = plan.transferFunctionURL {
        try sharedAppModel.transferFunction.save(to: url, description: dataset.description)
      }
      if let url = plan.viewStateURL {
        try DatasetStateStorage.saveViewState(
          try sharedAppModel.makeDatasetViewState(datasetID: dataset.uniqueId),
          to: url
        )
      }
      if let url = plan.objectURL {
        try DatasetStateStorage.saveObjects(
          datasetID: dataset.uniqueId,
          markers: sharedAppModel.volumeMarkers,
          meshInstances: sharedAppModel.sceneMeshInstances,
          to: url
        )
      }
      if let url = plan.measurementURL {
        try DatasetStateStorage.saveMeasurements(
          datasetID: dataset.uniqueId,
          measurements: sharedAppModel.volumeMeasurementsSnapshot(),
          to: url
        )
      }
    } catch {
      datasetStateSaveError = error
    }
  }

  private func restoreDatasetState() {
    guard let dataset = runtimeAppModel.activeDataset,
          let datasetInfo = runtimeAppModel.activeDatasetInfo else {
      showNoDatasetStateToRestore = true
      return
    }
    do {
      guard try sharedAppModel.restoreSavedDatasetState(
        datasetID: dataset.uniqueId,
        physicalExtent: datasetInfo.physicalExtentMeters,
        logger: runtimeAppModel.logger
      ) else {
        showNoDatasetStateToRestore = true
        return
      }
      sharedAppModel.synchronize(kind: .full)
      sharedAppModel.synchronizeMarkers()
      sharedAppModel.synchronizeMeasurements()
    } catch {
      datasetStateRestoreError = error
    }
  }

  private var canCopyWebGPUShareLink: Bool {
    guard let baseURL = serverController.shareableWebServerURL,
          let dataset = runtimeAppModel.activeDataset,
          serverController.datasets.contains(where: {
            $0.id.caseInsensitiveCompare(dataset.uniqueId) == .orderedSame
          }) else {
      return false
    }

    return baseURL.scheme == "https"
  }

  private func shareableWebGPUURL() -> URL? {
    guard let baseURL = serverController.shareableWebServerURL,
          let dataset = runtimeAppModel.activeDataset else {
      return nil
    }
    return WebGPUShareLink.datasetURL(
      baseURL: baseURL,
      datasetID: dataset.uniqueId,
      transferFunction: sharedAppModel.transferFunction,
      renderMode: sharedAppModel.renderMode,
      normalizedIsoValue: sharedAppModel.normIsoValue
    )
  }

  private func copyWebGPUShareLink() {
    guard let url = shareableWebGPUURL() else { return }
    WebGPUShareLink.copyToPasteboard(url.absoluteString)
    copiedWebGPUShareLink = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
      copiedWebGPUShareLink = false
    }
  }
}

/*
 Copyright (c) 2026 Computer Graphics and Visualization Group,
 University of Duisburg-Essen

 Permission is hereby granted, free of charge, to any person obtaining a
 copy of this software and associated documentation files (the "Software"),
 to deal in the Software without restriction, including without
 limitation the rights to use, copy, modify, merge, publish, distribute,
 sublicense, and/or sell copies of the Software, and to permit persons to
 whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included
 in all copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
 IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
 CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
 TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
 SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
