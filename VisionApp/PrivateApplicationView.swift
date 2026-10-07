import SwiftUI

struct HandInteractionControlsView: View {
  @Environment(RuntimeAppModel.self) private var runtimeAppModel
  @Environment(SharedAppModel.self) private var sharedAppModel

  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow

  @EnvironmentObject var storedAppModel: StoredAppModel
  @EnvironmentObject var voice: VoiceCommandService
  @EnvironmentObject var speech: SpeechHelper

  @State private var voiceHandler: VoiceCommandHandler?
  @State private var showResetModelConfirmation = false
  @State private var showResetClippingConfirmation = false
  @State private var showDeleteAllObjectsConfirmation = false
  @State private var showDeleteAllMeasurementsConfirmation = false
  @State private var transferFunctionCatalog: [TransferFunctionCatalogEntry] = []
  @State private var transferFunctionLoadError: Error?
  @State private var showTransferFunctionLoadError = false

  var body: some View {
    VStack(spacing: 10) {
      Text("private_interaction_title")
        .font(.headline)
        .bold()

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
    .alert("Reset Model?", isPresented: $showResetModelConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Reset", role: .destructive) {
        sharedAppModel.resetModel()
        sharedAppModel.synchronize(kind: .full)
      }
    } message: {
      Text("Do you really want to reset the model transformation?")
    }
    .alert("Reset Clipping?", isPresented: $showResetClippingConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Reset", role: .destructive) {
        sharedAppModel.resetClipBoundsToVolume()
        sharedAppModel.synchronize(kind: .full)
      }
    } message: {
      Text("Do you really want to reset the clipping bounds?")
    }
    .alert(
      "marker_clear_all_confirmation_title",
      isPresented: $showDeleteAllObjectsConfirmation
    ) {
      Button("marker_clear_all_confirmation_delete", role: .destructive) {
        deleteAllObjects()
      }
      Button("marker_clear_all_confirmation_cancel", role: .cancel) {}
    } message: {
      Text("marker_clear_all_confirmation_message")
    }
    .alert(
      "measurement_delete_all_confirmation_title",
      isPresented: $showDeleteAllMeasurementsConfirmation
    ) {
      Button("measurement_delete_all_confirmation_delete", role: .destructive) {
        deleteAllMeasurements()
      }
      Button("marker_clear_all_confirmation_cancel", role: .cancel) {}
    } message: {
      Text("measurement_delete_all_confirmation_message")
    }
    .alert(
      "tf_editor_import_failed_title",
      isPresented: $showTransferFunctionLoadError,
      presenting: transferFunctionLoadError
    ) { _ in
      Button("tf_editor_ok_button", role: .cancel) {}
    } message: { error in
      Text(error.localizedDescription)
    }
    .onAppear(perform: refreshTransferFunctionCatalog)
    .onReceive(NotificationCenter.default.publisher(
      for: TransferFunctionCatalog.didChangeNotification
    )) { _ in
      refreshTransferFunctionCatalog()
    }
    .onChange(of: runtimeAppModel.activeDataset?.uniqueId) { _, _ in
      refreshTransferFunctionCatalog()
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
        showsScreenView: hasSharedScreenView,
        resetModel: { showResetModelConfirmation = true },
        resetClipping: { showResetClippingConfirmation = true },
        transferFunctionCatalog: transferFunctionCatalog,
        resetTransfer: resetTransferFunction,
        loadTransferFunction: loadTransferFunction,
        resetDrawing: { showDeleteAllObjectsConfirmation = true },
        resetPlacement: { showDeleteAllObjectsConfirmation = true },
        resetMeasurement: { showDeleteAllMeasurementsConfirmation = true }
      )
      Text("private_windows_title")
        .font(.headline)
        .bold()
      modeWindowButtons(showTitles: showTitles)
    }
    .frame(minWidth: showTitles ? 640 : 480)
    .frame(maxWidth: .infinity, alignment: .center)
  }

  private func modeWindowButtons(showTitles: Bool) -> some View {
    GeometryReader { geometry in
      let columnCount = hasSharedScreenView ? 7 : 6
      let spacing: CGFloat = 4
      let columnWidth = max(
        0,
        (geometry.size.width - spacing * CGFloat(columnCount - 1)) /
          CGFloat(columnCount)
      )
      let columnStride = columnWidth + spacing
      let doubleColumnWidth = columnWidth * 2 + spacing

      ZStack(alignment: .leading) {
        lightingButton(showTitles: showTitles)
          .frame(width: columnWidth)
          .offset(x: columnStride)

        editorButton(showTitles: showTitles)
          .frame(width: columnWidth)
          .offset(x: columnStride * 2)

        markerWindowButton(showTitles: showTitles)
          .frame(width: doubleColumnWidth)
          .offset(x: columnStride * 3)

        measurementWindowButton(showTitles: showTitles)
          .frame(width: columnWidth)
          .offset(x: columnStride * 5)
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
      .frame(maxWidth: .infinity)
    }
    .help(String(localized: "Lighting"))
  }

  private func editorButton(showTitles: Bool) -> some View {
    Button(action: openSelectedEditor) {
      toolLabel(
        editorButtonTitle,
        systemImage: "slider.horizontal.3",
        color: InteractionModeColor.transfer,
        showTitle: showTitles,
        compactWidth: 60,
        compactHeight: 38,
        compactFont: .title3
      )
      .frame(maxWidth: .infinity)
    }
    .help(editorButtonTitle)
  }

  @ViewBuilder
  private func toolLabel(
    _ title: String,
    systemImage: String,
    color: Color,
    showTitle: Bool,
    compactWidth: CGFloat = 44,
    compactHeight: CGFloat = 32,
    compactFont: Font = .body
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
        .font(compactFont)
        .foregroundStyle(color)
        .frame(width: compactWidth, height: compactHeight)
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

  private func deleteAllObjects() {
    let removedMarkers = sharedAppModel.removeAllVolumeMarkers()
    let removedMeshes = !sharedAppModel.sceneMeshInstances.isEmpty
    sharedAppModel.sceneMeshInstances.removeAll()
    sharedAppModel.selectedSceneMeshInstanceID = nil
    if removedMarkers || removedMeshes {
      sharedAppModel.synchronizeMarkers()
    }
  }

  private func deleteAllMeasurements() {
    if sharedAppModel.removeAllVolumeMeasurements() {
      sharedAppModel.synchronizeMeasurements()
    }
  }

  private func resetTransferFunction() {
    sharedAppModel.transferFunction.reset()
    sharedAppModel.renderMode = .transferFunction1D
    sharedAppModel.synchronize(kind: .full)
  }

  private func loadTransferFunction(_ entry: TransferFunctionCatalogEntry) {
    do {
      try sharedAppModel.loadTransferFunction(from: entry.url)
      sharedAppModel.renderMode = .transferFunction1D
      sharedAppModel.synchronize(kind: .full)
    } catch {
      transferFunctionLoadError = error
      showTransferFunctionLoadError = true
      refreshTransferFunctionCatalog()
    }
  }

  private func refreshTransferFunctionCatalog() {
    transferFunctionCatalog = TransferFunctionCatalog.entries(
      additionalDirectoryURLs: FileManager.default.urls(
        for: .documentDirectory,
        in: .userDomainMask
      ),
      datasetTransferFunctionURL: datasetTransferFunctionURL,
      logger: runtimeAppModel.logger
    )
  }

  private var datasetTransferFunctionURL: URL? {
    guard let activeDataset = runtimeAppModel.activeDataset,
          let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
          ).first else {
      return nil
    }
    return documentsURL
      .appendingPathComponent(activeDataset.uniqueId)
      .appendingPathExtension("tf1d")
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
  static let transfer = Color.purple
  static let objects = Color.orange
  static let measurement = Color.green
  static let screenView = Color.purple

  static func color(for rawValue: String) -> Color {
    switch rawValue {
      case "model": model
      case "clipping": clipping
      case "transferEditing": transfer
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
  var resetModel: (() -> Void)? = nil
  var resetClipping: (() -> Void)? = nil
  var transferFunctionCatalog: [TransferFunctionCatalogEntry] = []
  var resetTransfer: (() -> Void)? = nil
  var loadTransferFunction: ((TransferFunctionCatalogEntry) -> Void)? = nil
  var resetDrawing: (() -> Void)? = nil
  var resetPlacement: (() -> Void)? = nil
  var resetMeasurement: (() -> Void)? = nil

  var body: some View {
    HStack(spacing: 4) {
      segment(
        "private_interaction_option_model",
        icon: "move.3d",
        value: "model",
        resetAction: resetModel,
        resetTitle: "Reset Model"
      )
      segment(
        "private_interaction_option_clipping",
        icon: "viewfinder",
        value: "clipping",
        resetAction: resetClipping,
        resetTitle: "Reset Clipping"
      )
      segment(
        "Transfer",
        icon: "slider.horizontal.3",
        value: "transferEditing",
        resetAction: resetTransfer,
        resetTitle: "Reset Transfer Function",
        showsTransferFunctionMenu: true
      )
      segment(
        "Draw",
        icon: "scribble",
        value: "drawing",
        resetAction: resetDrawing,
        resetTitle: "private_marker_clear_all_button"
      )
      segment(
        "Place",
        icon: "cube",
        value: "objectPlacement",
        resetAction: resetPlacement,
        resetTitle: "private_marker_clear_all_button"
      )
      segment(
        "private_interaction_option_measurement",
        icon: "ruler",
        value: "measurement",
        resetAction: resetMeasurement,
        resetTitle: "measurement_delete_all_button"
      )
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
    value: String,
    resetAction: (() -> Void)? = nil,
    resetTitle: LocalizedStringKey? = nil,
    showsTransferFunctionMenu: Bool = false
  ) -> some View {
    let isSelected = selection == value
    let color = InteractionModeColor.color(for: value)
    return VStack(spacing: 2) {
      if showsTransferFunctionMenu, let resetAction, let resetTitle {
        Menu {
          Button(action: resetAction) {
            Label("tf_reset_default", systemImage: "arrow.counterclockwise")
          }

          let presets = transferFunctionCatalog.filter { $0.source == .builtIn }
          if !presets.isEmpty {
            Section("tf_reset_presets") {
              ForEach(presets) { entry in
                Button {
                  loadTransferFunction?(entry)
                } label: {
                  Label(entry.displayName, systemImage: "waveform")
                }
              }
            }
          }

          let files = transferFunctionCatalog.filter { $0.source != .builtIn }
          if !files.isEmpty {
            Section("tf_reset_files") {
              ForEach(files) { entry in
                Button {
                  loadTransferFunction?(entry)
                } label: {
                  Label(entry.displayName, systemImage: "doc")
                }
              }
            }
          }
        } label: {
          resetIcon(color: color)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(resetTitle))
        .help(Text(resetTitle))
      } else if let resetAction, let resetTitle {
        Button(action: resetAction) {
          resetIcon(color: color)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(resetTitle))
        .help(Text(resetTitle))
      } else {
        Color.clear
          .frame(width: 24, height: 24)
          .accessibilityHidden(true)
      }

      Button {
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
    .frame(maxWidth: .infinity)
  }

  private func resetIcon(color: Color) -> some View {
    Image(systemName: "arrow.counterclockwise")
      .font(.caption)
      .foregroundStyle(color)
      .frame(width: 24, height: 24)
      .background(color.opacity(0.12), in: Circle())
      .contentShape(Circle())
  }
}
