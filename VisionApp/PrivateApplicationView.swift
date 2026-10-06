import SwiftUI

struct PrivateApplicationView: View {
  @Environment(RuntimeAppModel.self) private var runtimeAppModel
  @Environment(SharedAppModel.self) private var sharedAppModel

  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow

  @EnvironmentObject var storedAppModel: StoredAppModel
  @EnvironmentObject var voice: VoiceCommandService
  @EnvironmentObject var speech: SpeechHelper

  @State private var voiceHandler: VoiceCommandHandler?
  @State private var pendingDatasetStateSave: DatasetStateSavePlan?
  @State private var showDatasetStateOverwriteConfirmation = false
  @State private var showNoDatasetStateToSave = false
  @State private var datasetStateSaveError: Error?

  var body: some View {
    VStack() {
      ZStack {
        Text("private_interaction_title")
          .font(.title)
          .bold()
        HStack {
          Spacer()
          Button(action: requestDatasetStateSave) {
            Image(systemName: "archivebox")
          }
          .accessibilityLabel("Save Dataset State")
          .help("Save Dataset State")
        }
      }
      .padding()

      interactionControls(showTitles: false)

      if !sharedAppModel.sharePlayParticipants.isEmpty {
        HStack(spacing: 36) {
          Menu {
            ForEach(sharedAppModel.sharePlayParticipants) { participant in
              Label {
                Text(participant.displayName)
              } icon: {
                Image(systemName: participant.platform.systemImage)
                  .foregroundStyle(participantColor(participant))
              }
            }
          } label: {
            Label("Participants", systemImage: "person.2")
          }

          HStack(spacing: 8) {
            Text("Show Names")
            Toggle(
              "Show Names",
              isOn: Binding(
                get: { sharedAppModel.screenViewNamesVisible },
                set: { sharedAppModel.screenViewNamesVisible = $0 }
              )
            )
            .labelsHidden()
            .toggleStyle(.switch)
          }
          .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .center)
      }

      Spacer()

      VStack {
        Text("private_reset_section_title")
          .font(.title3)
          .bold()

        HStack {
          Button("private_reset_model_button") {
            sharedAppModel.resetModel()
            sharedAppModel.synchronize(kind: .full)
          }
          Button("private_reset_clipping_button") {
            sharedAppModel.resetClipBoundsToVolume()
            sharedAppModel.synchronize(kind: .full)
          }
          Button("private_reset_all_parameters_button") {
            sharedAppModel.reset()
            sharedAppModel.synchronize(kind: .full)
          }
        }
      }

      Spacer()

      if storedAppModel.enableVoiceInput {
        HStack() {
          Button(action: toggleVoice) {
            HStack(spacing: 10) {
              Image(
                systemName: voice.isEnabled ? "stop.circle.fill" : "mic.fill"
              )
              .font(.system(size: 18, weight: .semibold))

              Text(
                voice.isEnabled
                ? "private_voice_stop_button"
                : "private_voice_start_button"
              )
              .font(.headline)
              .contentTransition(.opacity)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(
              RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
          }
          .buttonStyle(.plain)
          .glassBackgroundEffect(in: .rect(cornerRadius: 24))
          .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
              .strokeBorder(
                voice.isEnabled ? (
                  voice.isPassive
                  ? Color.yellow.opacity(0.45)
                  : Color.red.opacity(0.45)
                )
                : Color.white.opacity(0.12),
                lineWidth: 2
              )
          )
          .shadow(radius: voice.isEnabled ? 14 : 6)
          .animation(
            .spring(response: 0.28, dampingFraction: 0.85),
            value: voice.isEnabled
          )
          .accessibilityLabel(
            voice.isEnabled
            ? NSLocalizedString(
              "private_voice_stop_label",
              comment: "Accessibility label: stop listening"
            )
            : NSLocalizedString(
              "private_voice_start_label",
              comment: "Accessibility label: start voice input"
            )
          )
          .onAppear {
            startupVoice()
          }

          Button(action: showVoiceHelp) {
            Image(systemName: "info.circle")
          }
        }
      }
    }
    .padding()
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
  }

  private func color(_ value: SIMD4<Float>) -> Color {
    Color(
      red: Double(value.x),
      green: Double(value.y),
      blue: Double(value.z),
      opacity: Double(value.w)
    )
  }

  private func participantColor(_ participant: BorgVRSharePlayParticipant) -> Color {
    guard participant.platform == .iOS || participant.platform == .macOS else {
      return .primary
    }
    return color(ScreenViewPresentation.color(for: participant))
  }

  private var hasSharedScreenView: Bool {
    sharedAppModel.screenSharePlayViewState != nil &&
      sharedAppModel.sharePlayParticipants.contains {
        $0.platform == .iOS || $0.platform == .macOS
      }
  }

  private var editorButtonTitle: String {
    String(
      format: NSLocalizedString(
        "private_editor_title_format",
        comment: "Button title: '<render mode> Editor'"
      ),
      String(describing: sharedAppModel.renderMode)
    )
  }

  private var interactionModeBinding: Binding<String> {
    Binding(
      get: { runtimeAppModel.interactionMode.rawValue },
      set: { value in
        if value != "drawing" && value != "objectPlacement" {
          sharedAppModel.clearVolumeMarkerSelection()
        }
        if value != "measurement" {
          sharedAppModel.selectedVolumeMeasurementPointID = nil
        }
        if let mode = RuntimeAppModel.InteractionMode(rawValue: value) {
          runtimeAppModel.interactionMode = mode
        }
      }
    )
  }

  private func interactionControls(showTitles: Bool) -> some View {
    VStack(spacing: 8) {
      InteractionModePicker(
        selection: interactionModeBinding,
        showsScreenView: hasSharedScreenView
      )
      modeWindowButtons(showTitles: showTitles)
    }
    .frame(minWidth: showTitles ? 640 : 480)
    .frame(maxWidth: .infinity, alignment: .center)
  }

  private func modeWindowButtons(showTitles: Bool) -> some View {
    GeometryReader { geometry in
      let columnCount = hasSharedScreenView ? 6 : 5
      let spacing: CGFloat = 4
      let columnWidth = max(
        0,
        (geometry.size.width - spacing * CGFloat(columnCount - 1)) /
          CGFloat(columnCount)
      )
      let columnStride = columnWidth + spacing
      let doubleColumnWidth = columnWidth * 2 + spacing
      let groupInset: CGFloat = showTitles ? 7 : 11

      ZStack(alignment: .leading) {
        HStack(spacing: showTitles ? 8 : 6) {
          editorButton(showTitles: showTitles)
          lightingButton(showTitles: showTitles)
        }
        .buttonStyle(.bordered)
        .frame(width: doubleColumnWidth - groupInset * 2)
        .offset(x: groupInset)

        markerWindowButton(showTitles: showTitles)
          .frame(width: doubleColumnWidth)
          .offset(x: columnStride * 2)

        measurementWindowButton(showTitles: showTitles)
          .frame(width: columnWidth)
          .offset(x: columnStride * 4)
      }
      .buttonStyle(.bordered)
    }
    .frame(height: showTitles ? 46 : 40)
  }

  private func markerWindowButton(showTitles: Bool) -> some View {
    Button {
      if !runtimeAppModel.isViewOpen("MarkerView") {
        openWindow(id: "MarkerView")
      }
    } label: {
      toolLabel(
        String(localized: "private_marker_open_button"),
        systemImage: "cube.transparent",
        color: InteractionModeColor.objects,
        showTitle: showTitles
      )
      .frame(maxWidth: .infinity)
    }
    .help(String(localized: "private_marker_open_button"))
  }

  private func measurementWindowButton(showTitles: Bool) -> some View {
    Button {
      if !runtimeAppModel.isViewOpen("MeasurementView") {
        openWindow(id: "MeasurementView")
      }
    } label: {
      toolLabel(
        String(localized: "measurement_window_title"),
        systemImage: "ruler",
        color: InteractionModeColor.measurement,
        showTitle: showTitles
      )
      .frame(maxWidth: .infinity)
    }
    .help(String(localized: "measurement_window_title"))
  }

  private func lightingButton(showTitles: Bool) -> some View {
    Button {
      if !runtimeAppModel.isViewOpen("LightingEditorView") {
        openWindow(id: "LightingEditorView")
      }
    } label: {
      toolLabel(
        String(localized: "Lighting"),
        systemImage: "lightbulb.max",
        color: .primary,
        showTitle: showTitles
      )
    }
    .help(String(localized: "Lighting"))
  }

  private func editorButton(showTitles: Bool) -> some View {
    Button(action: openSelectedEditor) {
      toolLabel(
        editorButtonTitle,
        systemImage: "slider.horizontal.3",
        color: .primary,
        showTitle: showTitles
      )
    }
    .help(editorButtonTitle)
  }

  @ViewBuilder
  private func toolLabel(
    _ title: String,
    systemImage: String,
    color: Color,
    showTitle: Bool
  ) -> some View {
    if showTitle {
      HStack(spacing: 7) {
        Image(systemName: systemImage)
          .foregroundStyle(color)
        Text(title)
      }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    } else {
      Image(systemName: systemImage)
        .foregroundStyle(color)
        .frame(width: 44, height: 32)
        .accessibilityLabel(title)
    }
  }

  func openSelectedEditor() {
    let targetId = (sharedAppModel.renderMode == .isoValue)
    ? "IsovalueEditorView"
    : "TransferFunctionEditorView"

    let otherId = (sharedAppModel.renderMode == .isoValue)
    ? "TransferFunctionEditorView"
    : "IsovalueEditorView"

    if !self.runtimeAppModel.isViewOpen(targetId) {
      openWindow(id: targetId)
    }

    if self.runtimeAppModel.isViewOpen(otherId) {
      dismissWindow(id: otherId)
    }
  }

  private func showVoiceHelp() {
    openWindow(id: "VoiceCommandsView")
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

  private func toggleVoice() {
    if voice.isEnabled {
      voice.stopListening()
      speak(
        NSLocalizedString(
          "private_voice_off",
          comment: "Spoken feedback when voice is turned off"
        )
      )
    } else {
      voice.startListening()
      speak(
        NSLocalizedString(
          "private_voice_on",
          comment: "Spoken feedback when voice is turned on"
        )
      )
    }
  }

  private func startupVoice() {
    voice.onMessage = { msg in
      switch msg {
        case .transcript(let text, let isFinal):
          handleVoiceCommand(text.lowercased(), isFinal: isFinal)
        case .stateChanged(let state):
          handleVoiceStateChange(state: state)
      }
    }

    switch voice.state {
      case .idle:
        voice.requestAuthorization(
          autostart: storedAppModel.enableVoiceInput
          && storedAppModel.autostartVoiceInput
        )
      case .failed(let error):
        runtimeAppModel.logger.warning(
          String(
            format: NSLocalizedString(
              "private_voice_usage_failed",
              comment: "Log: voice usage failed"
            ),
            String(describing: error)
          )
        )
        return
      case .denied(let error):
        runtimeAppModel.logger.warning(
          String(
            format: NSLocalizedString(
              "private_voice_usage_denied",
              comment: "Log: voice usage denied"
            ),
            String(describing: error)
          )
        )
        storedAppModel.enableVoiceInput = false
        return
      default:
        break
    }
  }

  private func handleVoiceCommand(_ text: String, isFinal: Bool) {
    let handler = ensureVoiceHandler()
    handler.handle(rawText: text, isFinal: isFinal)
  }

  private func handleVoiceStateChange(state: VoiceCommandService.State) {
    switch state {
      case .idle:
        break
      case .requestingAuth:
        break
      case .ready:
        break
      case .listening(_):
        break
      case .denied(let info):
        let messageDenied = String(
          format: NSLocalizedString(
            "private_voice_access_denied",
            comment: "Voice access denied (spoken/logged message)"
          ),
          info
        )
        speak(messageDenied)
        runtimeAppModel.logger.warning(messageDenied)
      case .failed(let info):
        let messageFailed = String(
          format: NSLocalizedString(
            "private_voice_failed",
            comment: "Voice failed (spoken/logged message)"
          ),
          info
        )
        speak(messageFailed)
        runtimeAppModel.logger.warning(messageFailed)
    }
  }

  func speak(_ text: String) {
    if storedAppModel.enableVoiceOutput {
      speech.speak(text)
    }
  }

  private func ensureVoiceHandler() -> VoiceCommandHandler {
    if let handler = voiceHandler {
      return handler
    }

    let handler = VoiceCommandHandler(
      runtimeAppModel: runtimeAppModel,
      sharedAppModel: sharedAppModel,
      storedAppModel: storedAppModel,
      voice: voice,
      speak: { message in
        speech.speak(message)
      },
      openSelectedEditor: {
        openSelectedEditor()
      }
    )
    voiceHandler = handler
    return handler
  }
}

enum InteractionModeColor {
  static let model = Color.blue
  static let clipping = Color.cyan
  static let objects = Color.orange
  static let measurement = Color.green
  static let screenView = Color.purple

  static func color(for rawValue: String) -> Color {
    switch rawValue {
      case "model": model
      case "clipping": clipping
      case "drawing", "objectPlacement": objects
      case "measurement": measurement
      case "screenView": screenView
      default: .primary
    }
  }
}

struct InteractionModePicker: View {
  @Binding var selection: String
  let showsScreenView: Bool

  var body: some View {
    HStack(spacing: 4) {
      segment("private_interaction_option_model", icon: "move.3d", value: "model")
      segment("private_interaction_option_clipping", icon: "viewfinder", value: "clipping")
      segment("Draw", icon: "scribble", value: "drawing")
      segment("Place", icon: "cube", value: "objectPlacement")
      segment("private_interaction_option_measurement", icon: "ruler", value: "measurement")
      if showsScreenView {
        segment("Screen View", icon: "display", value: "screenView")
      }
    }
    .padding(4)
    .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("private_interaction_picker_label"))
  }

  private func segment(
    _ title: LocalizedStringKey,
    icon: String,
    value: String
  ) -> some View {
    let isSelected = selection == value
    let color = InteractionModeColor.color(for: value)
    return Button {
      selection = value
    } label: {
      Label(title, systemImage: icon)
        .font(.callout)
        .fontWeight(isSelected ? .semibold : .regular)
        .foregroundStyle(color)
        .lineLimit(1)
        .frame(maxWidth: .infinity, minHeight: 34)
        .padding(.horizontal, 7)
        .background(
          color.opacity(isSelected ? 0.24 : 0),
          in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}
