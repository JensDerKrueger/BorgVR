import SwiftUI

struct VolumeExportAvailability: ViewModifier {
  @ObservedObject var model: VolumeBrushModel
  func body(content: Content) -> some View { content.disabled(!model.canExport) }
}

struct VolumeBrushActivityIndicator: View {
  @ObservedObject var model: VolumeBrushModel

  var body: some View {
    if model.isUpdatingBricks {
      Circle()
        .fill(.red)
        .overlay(Circle().stroke(.background, lineWidth: 1))
        .frame(width: 8, height: 8)
        .offset(x: 2, y: -2)
        .help("Updating Volume Bricks")
        .accessibilityLabel("Updating Volume Bricks")
        .allowsHitTesting(false)
    }
  }
}

struct VolumeEditSynchronizationStatus: View {
  @ObservedObject var model: VolumeBrushModel
  var body: some View {
    if model.isWaitingForSharedState {
      VStack(spacing: 4) {
        ProgressView("Synchronizing Edit State…").controlSize(.small)
        if let error = model.error {
          Text(error).font(.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .center)
    }
  }
}

struct VolumeEditResetButton: View {
  @ObservedObject var model: VolumeBrushModel
  @State private var showsConfirmation = false

  var body: some View {
    Button { showsConfirmation = true } label: {
      Image(systemName: "arrow.counterclockwise")
        .foregroundStyle(.red)
        .frame(width: 24, height: 24)
#if !os(visionOS)
        .contentShape(Rectangle())
#endif
    }
#if os(visionOS)
    .buttonStyle(.bordered)
    .buttonBorderShape(.circle)
    .controlSize(.mini)
#else
    .buttonStyle(.plain)
#endif
    .help("Discard All Edits")
    .accessibilityLabel("Discard All Edits")
    .disabled(model.isExporting || model.isDiscardingEdits || model.isOpeningState ||
      model.isRestoringPersonalState || model.isWaitingForSharedState)
    .modifier(VolumeEditResetConfirmation(model: model, showsConfirmation: $showsConfirmation))
  }
}

private struct VolumeEditResetConfirmation: ViewModifier {
  @ObservedObject var model: VolumeBrushModel
  @Binding var showsConfirmation: Bool
  func body(content: Content) -> some View {
    content.alert("Discard All Volume Edits?", isPresented: $showsConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Discard All Edits", role: .destructive) { model.discardAllEdits() }
    } message: {
      Text("All edits in the active state will be removed. During SharePlay this clears the shared state for everyone. Other states and the original dataset are preserved.")
    }
  }
}

struct VolumeBrushControls: View {
#if os(macOS)
  @Environment(\.panelWindow) private var panelWindow
  @State private var showsDiscardConfirmation = false
#endif
  @ObservedObject var model: VolumeBrushModel
  @State private var showsExportDialog = false
  var body: some View {
    VStack(spacing: 8) {
      VolumeEditStateControls(model: model)
      VolumeEditSynchronizationStatus(model: model)
#if os(macOS)
      if panelWindow == nil {
        HStack { Spacer(); VolumeEditResetButton(model: model) }
      }
#else
      HStack {
        Spacer()
        VolumeEditResetButton(model: model)
      }
#endif
      Picker("Brush", selection: $model.mode) {
        Label("Erase", systemImage: "eraser.fill").tag(BorgVRVolumeBrushMode.erase)
        Label("Restore", systemImage: "arrow.uturn.backward").tag(BorgVRVolumeBrushMode.restore)
      }
      .pickerStyle(.segmented)
#if os(macOS)
      .help([
        MacRenderShortcut.help("Erase", shortcut: .erase),
        MacRenderShortcut.help("Restore", shortcut: .restore)
      ].joined(separator: " · "))
#endif
      if model.componentCount > 1 && model.channelInterpretation == .independentChannels {
        DisclosureGroup("Edit Channels") {
          Toggle("All Channels", isOn: Binding(get: { model.channels == .all }, set: { all in
            try? model.setVolumeBrushChannels(all ? .all : .selected([0]))
          }))
          ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], alignment: .leading, spacing: 8) {
              ForEach(0..<model.componentCount, id: \.self) { channel in
                Toggle(String(format: String(localized: "Channel %lld"), Int64(channel + 1)), isOn: Binding(
                  get: { model.channels.contains(channel) },
                  set: { enabled in
                    var selected = (0..<model.componentCount).filter { model.channels.contains($0) }
                    selected.removeAll { $0 == channel }
                    if enabled { selected.append(channel) }
                    try? model.setVolumeBrushChannels(.selected(selected))
                  }))
                  .disabled(model.channels == .selected([channel]))
              }
            }
          }
          .frame(maxHeight: 144)
        }
      }
      HStack {
        Text("Radius")
        Slider(value: $model.radius, in: BorgVRVolumeBrushLimits.radiusFraction)
#if os(macOS)
          .help([
            MacRenderShortcut.help("Smaller Brush", shortcut: .smallerBrush),
            MacRenderShortcut.help("Larger Brush", shortcut: .largerBrush)
          ].joined(separator: " · "))
#endif
        Text(PhysicalSizeFormatter.length(meters: Double(model.physicalMaximum) * model.radius) ?? "")
          .monospacedDigit()
          .frame(minWidth: 64, alignment: .trailing)
      }
      Toggle("Project onto Volume", isOn: $model.projectsOntoVolume)
      Text("SharePlay uses a separate shared edit state. Your personal edits are preserved.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button {
        model.prepareExport()
        showsExportDialog = true
      } label: {
        Label("Export Edited Dataset", systemImage: "square.and.arrow.up")
      }
      .disabled(!model.canExport)
      if let error = model.error {
        Text(error).foregroundStyle(.red).font(.caption).fixedSize(horizontal: false, vertical: true)
      }
    }
    .screenControlButtons()
    .disabled(model.isDiscardingEdits || model.isOpeningState || model.isRestoringPersonalState)
    .onAppear { model.refreshStates() }
    .padding(.vertical, 6)
#if os(macOS)
    .panelParameters(kind: "brush",
      reset: .button("reset", icon: "arrow.counterclockwise", text: String(localized: "Discard All Edits"),
        enabled: !model.isExporting && !model.isDiscardingEdits && !model.isOpeningState &&
          !model.isRestoringPersonalState && !model.isWaitingForSharedState) { showsDiscardConfirmation = true },
      snapshot: { BrushPanelPreset(model: model) },
      apply: { try $0.apply(to: model) })
    .modifier(VolumeEditResetConfirmation(model: model, showsConfirmation: $showsDiscardConfirmation))
#endif
    .sheet(isPresented: $showsExportDialog, onDismiss: model.dismissExportDialog) {
      VolumeBrushExportDialog(model: model)
    }
  }
}

extension BorgVRVolumeEditState {
  var displayName: String {
    if !name.isEmpty { return name }
    switch kind {
      case .local: return String(localized: "Local Edits")
      case .copy: return String(localized: "Edit Copy")
      case .sharePlay: return "SharePlay – " + createdAt.formatted(date: .numeric, time: .shortened)
    }
  }
}

private struct VolumeEditStateControls: View {
  @ObservedObject var model: VolumeBrushModel
  @State private var rename = false
  @State private var name = ""
  @State private var delete = false
  @State private var error: String?

  var body: some View {
    VStack(spacing: 8) {
      if model.isInSharePlay {
        Label("Shared Edit State", systemImage: "shareplay").font(.caption)
      } else {
        Picker("Edit State", selection: Binding<UUID?>(get: { model.activeState?.id }, set: { id in
          perform { try await model.selectState(id) }
        })) {
          Text("Original – No Edits").tag(nil as UUID?)
          ForEach(model.states) { state in Text(state.displayName).tag(Optional(state.id)) }
        }
        .pickerStyle(.menu)
        .lineLimit(1)
        .screenControlMenu()
        HStack {
          Button { perform { try await model.duplicateState(empty: true) } } label: { Image(systemName: "plus") }
            .help("New Edit State").accessibilityLabel("New Edit State")
          Button { perform { try await model.duplicateState() } } label: { Image(systemName: "doc.on.doc") }
            .help("Duplicate Edit State").accessibilityLabel("Duplicate Edit State")
          Button { name = model.activeState?.displayName ?? ""; rename = true } label: { Image(systemName: "pencil") }
            .help("Rename Edit State").accessibilityLabel("Rename Edit State")
            .disabled(model.activeState == nil)
          Button(role: .destructive) { delete = true } label: { Image(systemName: "trash") }
            .help("Delete Edit State").accessibilityLabel("Delete Edit State")
            .disabled(model.activeState == nil)
          Spacer()
        }
      }
    }
    .disabled(model.isOpeningState || model.isExporting || model.isRestoringPersonalState)
    .onChange(of: model.isInSharePlay) { _, active in
      if active { rename = false; delete = false }
    }
    .alert("Rename Edit State", isPresented: $rename) {
      TextField("Name", text: $name)
      Button("Cancel", role: .cancel) {}
      Button("Save") {
        guard let id = model.activeState?.id else { return }
        perform { try model.renameState(id, name: name) }
      }
      .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .alert("volume_edit_state_delete_confirmation_title", isPresented: $delete) {
      Button("Cancel", role: .cancel) {}
      Button("Delete", role: .destructive) {
        guard let id = model.activeState?.id else { return }
        perform { try await model.selectState(nil); try model.deleteState(id) }
      }
    } message: { Text("Only this edit state will be deleted. The original dataset and other edit states are preserved.") }
    .alert("Edit State Error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
      Button("OK", role: .cancel) {}
    } message: { Text(error ?? "") }
  }

  private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
    Task { do { try await operation() } catch { self.error = error.localizedDescription } }
  }
}

private enum VolumeEditDialog: Identifiable {
  case selection(VolumeEditOpeningRequest)
  case preparation(UUID)
  var id: UUID {
    switch self { case .selection(let request): request.id; case .preparation(let id): id }
  }
}

private struct VolumeEditSelectionModifier: ViewModifier {
  @ObservedObject var model: VolumeBrushModel
  var isPresentationEnabled = true
  func body(content: Content) -> some View {
    content.sheet(item: Binding<VolumeEditDialog?>(get: {
      guard isPresentationEnabled else { return nil }
      if let request = model.openingRequest { return .selection(request) }
      return model.preparationID.map { .preparation($0) }
    }, set: { value in
      if isPresentationEnabled, value == nil, let request = model.openingRequest {
        model.cancelOpeningSelection(id: request.id)
      }
    })) { dialog in
      switch dialog {
        case .selection(let request):
          VolumeEditSelectionView(model: model, request: request)
            .onDisappear { model.cancelOpeningSelection(id: request.id) }
        case .preparation(let id):
          VStack(alignment: .leading, spacing: 16) {
            Text("Preparing Edit State").font(.headline)
            Text("Finishing pending volume updates before opening.").fixedSize(horizontal: false, vertical: true)
            ProgressView(value: model.preparationProgress)
            Text(model.preparationProgress, format: .percent.precision(.fractionLength(0))).monospacedDigit()
            Text("Cancel opens the dataset immediately; pending edits continue in the background.")
              .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
              Spacer()
              Button("Cancel", role: .cancel) { model.cancelOpeningPreparation(id: id) }
                .keyboardShortcut(.cancelAction)
            }
          }
          .padding(24).frame(idealWidth: 420)
          .presentationDetents([.height(300)])
          .interactiveDismissDisabled()
      }
    }
    .alert("Edit State Error", isPresented: Binding(
      get: { isPresentationEnabled && model.openingError != nil },
      set: { if isPresentationEnabled && !$0 { model.openingError = nil } }
    )) { Button("OK", role: .cancel) { model.openingError = nil } }
    message: { Text(model.openingError ?? "") }
  }
}

extension View {
  func volumeEditSelectionDialog(model: VolumeBrushModel, isPresentationEnabled: Bool = true) -> some View {
    modifier(VolumeEditSelectionModifier(model: model, isPresentationEnabled: isPresentationEnabled))
  }
}

private struct VolumeEditSelectionView: View {
#if os(visionOS)
  private enum RowSelection: Hashable {
    case original
    case edit(UUID)
  }

  private var rowSelection: Binding<RowSelection?> {
    Binding(get: { selection.map(RowSelection.edit) ?? .original }, set: { row in
      switch row {
        case .original: selection = nil
        case .edit(let id): selection = id
        case nil: break
      }
    })
  }
#endif
  @ObservedObject var model: VolumeBrushModel
  let request: VolumeEditOpeningRequest
  @State private var selection: UUID?
  @State private var items: [BorgVRVolumeEditState]
  @State private var pendingDelete: BorgVRVolumeEditState?
  @State private var error: String?

  init(model: VolumeBrushModel, request: VolumeEditOpeningRequest) {
    self.model = model; self.request = request
    _selection = State(initialValue: request.preferredID)
    _items = State(initialValue: request.states)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Choose Edit State").font(.headline)
      Text("Which edit state would you like to open?").fixedSize(horizontal: false, vertical: true)
      stateList
      .frame(minHeight: 180, idealHeight: 260, maxHeight: 400)
      HStack {
        Button("Cancel", role: .cancel) { model.cancelOpeningSelection(id: request.id) }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button("Open") { model.completeOpeningSelection(id: request.id, stateID: selection) }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(idealWidth: 460)
    .presentationDetents([.medium, .large])
    .alert("volume_edit_state_delete_confirmation_title", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { state in
      Button("Cancel", role: .cancel) { pendingDelete = nil }
      Button("Delete", role: .destructive) {
        do {
          try model.deleteOpeningState(state.id, requestID: request.id)
          items.removeAll { $0.id == state.id }
          if selection == state.id { selection = nil }
        } catch { self.error = error.localizedDescription }
        pendingDelete = nil
      }
    } message: { _ in Text("Only this edit state will be deleted. The original dataset and other edit states are preserved.") }
    .alert("Edit State Error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
      Button("OK", role: .cancel) {}
    } message: { Text(error ?? "") }
  }

  private var stateList: some View {
#if os(visionOS)
    List(selection: rowSelection) { stateRows }
#else
    List { stateRows }
#endif
  }

  @ViewBuilder
  private var stateRows: some View {
    choice(nil, title: String(localized: "Original – No Edits"))
#if os(visionOS)
      .tag(RowSelection.original)
#endif
    ForEach(items) { state in
      HStack {
        choice(state.id, title: state.displayName, date: state.modifiedAt)
        Button(role: .destructive) { pendingDelete = state } label: { Image(systemName: "trash") }
          .buttonStyle(.borderless)
          .accessibilityLabel("Delete Edit State")
          .help("Delete Edit State")
          .disabled(!model.canDeleteOpeningState(state.id, requestID: request.id))
      }
#if os(visionOS)
      .tag(RowSelection.edit(state.id))
#endif
    }
  }

  @ViewBuilder
  private func choice(_ id: UUID?, title: String, date: Date? = nil) -> some View {
#if os(visionOS)
    choiceLabel(id, title: title, date: date)
#else
    Button { selection = id } label: {
      choiceLabel(id, title: title, date: date)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
#endif
  }

  private func choiceLabel(_ id: UUID?, title: String, date: Date?) -> some View {
    HStack(spacing: 12) {
      Image(systemName: selection == id ? "checkmark.circle.fill" : "circle").foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 4) {
        Text(title).foregroundStyle(.primary)
        if let date { Text(date, format: .dateTime).font(.caption).foregroundStyle(.secondary) }
      }
      Spacer()
    }
  }
}

private struct VolumeBrushExportDialog: View {
  @ObservedObject var model: VolumeBrushModel
  @Environment(\.dismiss) private var dismiss
  @State private var showsSave = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Export Edited Dataset").font(.headline)
      if model.exportPhase == .options {
        Text("Name")
        TextField("Name", text: $model.exportName)
          .textFieldStyle(.roundedBorder)
        Text("tf_save_dialog_description_placeholder")
        TextEditor(text: $model.exportDescription)
          .frame(height: 100)
          .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.4)))
          .accessibilityLabel("tf_save_dialog_description_placeholder")
      } else {
        Text(model.exportName).lineLimit(2)
        ProgressView(value: model.exportProgress)
        Text(model.exportProgress, format: .percent.precision(.fractionLength(0)))
          .monospacedDigit()
        if model.exportPhase == .cancelling {
          Text("volume_edit_export_cancelling").foregroundStyle(.secondary)
        }
      }
      if let error = model.error {
        Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Button {
          if model.isExporting { model.cancelExport() }
          else { dismiss() }
        } label: {
          Label("Cancel", systemImage: "xmark")
        }
        .keyboardShortcut(.cancelAction)
        .disabled(model.exportPhase == .cancelling)
        Spacer()
        if model.exportPhase == .options {
          Button { model.export() } label: {
            Label("Export", systemImage: "square.and.arrow.up")
          }
          .keyboardShortcut(.defaultAction)
          .disabled(!model.canExport || model.exportName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } else if model.exportPhase == .ready, model.exportedURL != nil {
          Button { showsSave = true } label: {
            Label("tf_save_dialog_save_button", systemImage: "folder")
          }
          .keyboardShortcut(.defaultAction)
        }
      }
    }
    .padding(24)
    .frame(idealWidth: 440)
    .interactiveDismissDisabled(model.isExporting)
    .onChange(of: model.exportPhase) { _, phase in
      if phase == .ready, model.exportedURL != nil { showsSave = true }
      if phase == .cancelled { dismiss() }
    }
    .onChange(of: model.isInSharePlay) { _, active in
      if active, model.exportPhase == .options { dismiss() }
    }
    .fileMover(isPresented: $showsSave, file: model.exportedURL) { result in
      if model.exportMoveCompleted(result) { dismiss() }
    }
  }
}
