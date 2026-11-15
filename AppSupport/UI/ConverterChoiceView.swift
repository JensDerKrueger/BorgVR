import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

enum SupportingFileAccessExplanation {
  static func shouldShow(defaults: UserDefaults = .standard) -> Bool {
    ExplanationDialogPreference.supportingFileAccess.shouldShow(defaults: defaults)
  }

  static func disable(defaults: UserDefaults = .standard) {
    ExplanationDialogPreference.supportingFileAccess.disable(defaults: defaults)
  }

  static var title: String {
    String(localized: "Access to the volume data", table: "ImportMessages")
  }

  static var dismissPermanentlyTitle: String {
    String(localized: "Don't explain again", table: "ImportMessages")
  }

  static func message(for url: URL) -> String {
    String(format: String(localized:
      "The selected header describes the volume and references \"%@\". For security reasons, selecting the header does not automatically grant access to that file. Please select the referenced file to continue importing.",
      table: "ImportMessages"), url.lastPathComponent)
  }
}

enum VolumeImportKind: String, CaseIterable, Identifiable {
  case volumeFile
  case dicomDirectory
  case imageSequence
  case volumeFusion

  var id: Self { self }

  var compactWizardStepCount: Int {
    switch self {
      case .volumeFusion: 5
      case .dicomDirectory, .volumeFile, .imageSequence: 4
    }
  }

  func macWizardStepCount(referenceIsDICOM: Bool = false, registeredIsDICOM: Bool = false) -> Int {
    switch self {
      case .volumeFile: 7
      case .dicomDirectory, .imageSequence: 8
      case .volumeFusion: 8 + (referenceIsDICOM ? 1 : 0) + (registeredIsDICOM ? 1 : 0)
    }
  }

  var title: LocalizedStringKey {
    switch self {
      case .volumeFile: "Volume File"
      case .dicomDirectory: "DICOM Series"
      case .volumeFusion: "Volume Fusion"
      case .imageSequence: "Image Sequence"
    }
  }

  var systemImage: String {
    switch self {
      case .volumeFile: "doc"
      case .dicomDirectory: "cross.case"
      case .volumeFusion: "square.3.layers.3d"
      case .imageSequence: "photo.on.rectangle.angled"
    }
  }
}

enum VolumeImportWizardStep: Int, CaseIterable {
  case source, options, conversion

  var number: Int { rawValue + 2 }
  var next: Self? { Self(rawValue: rawValue + 1) }
  var previous: Self? { Self(rawValue: rawValue - 1) }

  func canContinue(sourceSelected: Bool, sizeIsValid: Bool = true) -> Bool {
    self != .conversion && sourceSelected && (self == .source || sizeIsValid)
  }

  func canStart(sourceSelected: Bool, sizeIsValid: Bool = true) -> Bool {
    self == .conversion && sourceSelected && sizeIsValid
  }
}

enum DirectoryImportWizardStep: Int, CaseIterable {
  case directory, options

  var number: Int { rawValue + 2 }
  var next: Self? { Self(rawValue: rawValue + 1) }
  var previous: Self? { Self(rawValue: rawValue - 1) }

  func canContinue(directorySelected: Bool, sizeIsValid: Bool = true) -> Bool {
    directorySelected && (self == .directory || sizeIsValid)
  }
}

enum DICOMSourceWizardStep: Int, CaseIterable {
  case directory, preview

  var next: Self? { Self(rawValue: rawValue + 1) }
  var previous: Self? { Self(rawValue: rawValue - 1) }
}

enum VolumeFusionWizardStep: Int, CaseIterable {
  case reference, registered, options, conversion

  var number: Int { rawValue + 2 }
  var next: Self? { Self(rawValue: rawValue + 1) }
  var previous: Self? { Self(rawValue: rawValue - 1) }
  var sourceTitle: LocalizedStringKey? {
    switch self {
      case .reference: "Reference Volume"
      case .registered: "Volume to Register"
      case .options, .conversion: nil
    }
  }

  func canContinue(referenceSelected: Bool, registeredSelected: Bool) -> Bool {
    switch self {
      case .reference: referenceSelected
      case .registered, .options: referenceSelected && registeredSelected
      case .conversion: false
    }
  }

  func canStart(referenceSelected: Bool, registeredSelected: Bool) -> Bool {
    self == .conversion && referenceSelected && registeredSelected
  }
}

struct VolumeFusionSelection {
  enum Kind: String, CaseIterable, Identifiable {
    case file, dicom, zarr
    var id: Self { self }
    var title: LocalizedStringKey {
      switch self {
        case .file: "Volume File"
        case .dicom: "DICOM Series"
        case .zarr: "Zarr Folder"
      }
    }
  }
  var kind: Kind = .dicom
  var access: VolumeImportSourceAccess?
  var input: BorgVRVolumeInput? {
    guard let access else { return nil }
    return kind == .dicom ? .dicomDirectory(access.url) : .file(access.url)
  }
}

struct VolumeFusionSourcePicker: View {
  let title: LocalizedStringKey
  @Binding var selection: VolumeFusionSelection
  var onSourceSelected: (() -> Void)? = nil
#if !os(macOS)
  @State private var pickerMode: FilePickerView.Mode?
#endif

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title).font(.headline)
      Picker("Source type", selection: $selection.kind) {
        ForEach(VolumeFusionSelection.Kind.allCases) { kind in
          Text(kind.title).tag(kind)
        }
      }
      .pickerStyle(.menu)
      Button(action: selectSource) {
        Label("Select Source", systemImage: selection.kind == .file ? "doc" : "folder")
      }
      Text(selection.access?.url.lastPathComponent ?? String(localized: "No source selected"))
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .truncationMode(.middle)
      if selection.kind == .file {
#if os(visionOS) || os(iOS)
        ConverterVolumeFormatButton(includesNativeBorgVR: true)
          .padding(.top, 8)
#else
        ConverterVolumeFormatList(includesNativeBorgVR: true)
          .padding(.top, 8)
#endif
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .onChange(of: selection.kind) { _, _ in selection.access = nil }
#if !os(macOS)
    .sheet(item: $pickerMode) { mode in
      FilePickerView(mode: mode) { access in
        pickerMode = nil
        if let access {
          selection.access = access
          onSourceSelected?()
        }
      }
    }
#endif
  }

  private func selectSource() {
#if os(macOS)
    let panel = NSOpenPanel()
    panel.canChooseFiles = selection.kind == .file
    panel.canChooseDirectories = selection.kind != .file
    panel.allowsMultipleSelection = false
    if selection.kind == .file {
      panel.allowedContentTypes = (VolumeFileParserFactory.supportedExtensions + ["data"])
        .compactMap { UTType(filenameExtension: $0) }
    }
    if panel.runModal() == .OK, let url = panel.url {
      selection.access = VolumeImportSourceAccess(url: url, selectedURLs: [url])
      onSourceSelected?()
    }
#else
    switch selection.kind {
      case .file: pickerMode = .files
      case .dicom: pickerMode = .dicomDirectory
      case .zarr: pickerMode = .zarrDirectory
    }
#endif
  }
}

struct ConverterChoiceItem: Identifiable {
  let id: String
  let title: LocalizedStringKey
  let systemImage: String
  var startsSection = false
  let action: () -> Void
}

struct ConverterVolumeFormatList: View {
  var includesNativeBorgVR = false
  var showsTitle = true

  private let formats = [
    ("QVIS", ".dat + .raw"),
    ("NRRD / NHDR", ".nrrd, .nhdr"),
    ("PVM / PVM2 / PVM3", ".pvm"),
    ("IV3Dm", ".i3m, .i3m.zip"),
    ("UVF", ".uvf"),
    ("VFF", ".vff"),
    ("Zarr / OME-Zarr", ".zarr, .ozx")
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if showsTitle {
        Text("Supported volume formats")
          .font(.subheadline.weight(.semibold))
      }
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
        ForEach(formats, id: \.0) { format in
          formatRow(format.0, extensions: format.1)
        }
        if includesNativeBorgVR {
          formatRow("BorgVR", extensions: ".data")
        }
      }
      .font(.subheadline)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func formatRow(_ name: String, extensions: String) -> some View {
    GridRow(alignment: .firstTextBaseline) {
      Text(verbatim: name)
        .fixedSize(horizontal: false, vertical: true)
      Text(verbatim: extensions)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

#if os(visionOS)
struct ConverterWizardFooter<Leading: View, Actions: View>: View {
  @ViewBuilder let leading: Leading
  @ViewBuilder let actions: Actions

  var body: some View {
    HStack(spacing: 12) {
      leading
      Spacer(minLength: 24)
      actions
    }
    .font(.headline)
    .buttonStyle(.bordered)
    .buttonBorderShape(.capsule)
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(minHeight: 80)
  }
}
#endif

#if os(visionOS) || os(iOS)
struct ConverterVolumeFormatButton: View {
  var includesNativeBorgVR = false
  @State private var showsFormats = false

  var body: some View {
    Button { showsFormats = true } label: {
      Label("Supported volume formats", systemImage: "info.circle")
    }
    .sheet(isPresented: $showsFormats) {
#if os(iOS)
      NavigationStack {
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            ConverterVolumeFormatList(includesNativeBorgVR: includesNativeBorgVR, showsTitle: false)
            Text("For `.dat` and `.nhdr`, iOS also needs access to the referenced raw data file.")
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(24)
        }
        .navigationTitle("Supported volume formats")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { showsFormats = false }
          }
        }
      }
      .presentationDetents([.medium, .large])
#else
      VStack(alignment: .leading, spacing: 20) {
        Text("Supported volume formats")
          .font(.title2.bold())
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            ConverterVolumeFormatList(includesNativeBorgVR: includesNativeBorgVR, showsTitle: false)
            Text("For QVIS and NHDR, select both the metadata and referenced raw data files.")
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        HStack {
          Spacer()
          Button("Done") { showsFormats = false }
            .keyboardShortcut(.defaultAction)
        }
      }
      .padding(24)
      .frame(width: 640, height: 540)
#endif
    }
  }
}
#endif

struct ConverterWizardHeader: View {
  let title: LocalizedStringKey
  let step: Int
  let total: Int?

  private var stepDescription: String {
    if let total {
      return String(format: NSLocalizedString("converter_step_of_total_format", comment: ""), step, total)
    }
    return String(format: String(localized: "Step %ld", table: "ImportMessages"), step)
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
        .font(.title.bold())
        .fixedSize(horizontal: false, vertical: true)
        .padding()
      Text(stepDescription)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }
  }
}

struct ConverterWizardStepIcon: View {
  let systemImage: String
  var compact = false

  var body: some View {
    Image(systemName: systemImage)
      .font(.system(size: compact ? 28 : 42, weight: .medium))
      .foregroundStyle(.tint)
      .frame(width: compact ? 64 : 100, height: compact ? 64 : 100)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: compact ? 8 : 20))
      .padding(compact ? 8 : 16)
      .accessibilityHidden(true)
  }
}

struct ConverterWizardSelectionStep: View {
  let title: LocalizedStringKey
  let question: LocalizedStringKey
  let systemImage: String
  let step: Int
  let total: Int?
  let choices: [ConverterChoiceItem]
  let selectedID: String?
  var canGoBack = true
  var showsNavigation = true
  var onCancel: (() -> Void)? = nil
  let onBack: () -> Void
  let onNext: () -> Void

  var body: some View {
    VStack(spacing: 16) {
      ConverterWizardHeader(title: title, step: step, total: total)
      Spacer()
      GeometryReader { geometry in
        ScrollView {
          if geometry.size.width < 600 {
            VStack(alignment: .leading, spacing: 12) {
              HStack {
                ConverterWizardStepIcon(systemImage: systemImage, compact: true)
                questionLabel
              }
              choiceList
            }
          } else {
            HStack(alignment: .top) {
              ConverterWizardStepIcon(systemImage: systemImage)
              VStack(alignment: .leading, spacing: 12) {
                questionLabel
                choiceList
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
      }
      Spacer()
      if showsNavigation {
#if os(visionOS)
        ConverterWizardFooter {
          EmptyView()
        } actions: {
          if let onCancel {
            Button(action: onCancel) { Label("Cancel", systemImage: "xmark") }
          }
          Button(action: onBack) {
            Label("converter_button_back", systemImage: "chevron.backward")
              .frame(minWidth: 120)
          }
          .disabled(!canGoBack)
          Button(action: onNext) {
            Label("converter_nav_next", systemImage: "chevron.forward")
              .frame(minWidth: 240)
          }
          .buttonStyle(.borderedProminent)
          .disabled(selectedID == nil)
        }
#else
        HStack(spacing: 16) {
          Spacer()
          if let onCancel {
            Button(action: onCancel) { Label("Cancel", systemImage: "xmark") }
          }
          Button(action: onBack) { Label("converter_button_back", systemImage: "chevron.backward") }
            .disabled(!canGoBack)
          Button(action: onNext) { Label("converter_nav_next", systemImage: "chevron.forward") }
            .buttonStyle(.borderedProminent)
            .disabled(selectedID == nil)
        }
#endif
      }
    }
  }

  private var questionLabel: some View {
    Text(question)
      .font(.headline)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var choiceList: some View {
    VStack(spacing: 4) {
      ForEach(choices) { choice in
        let selected = choice.id == selectedID
        if choice.startsSection {
          Divider()
            .padding(.vertical, 8)
        }
        Button(action: choice.action) {
          HStack(spacing: 12) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
#if !os(visionOS)
              .foregroundStyle(selected ? Color.accentColor : .secondary)
#endif
            Image(systemName: choice.systemImage)
#if !os(visionOS)
              .foregroundStyle(.tint)
#endif
              .frame(width: 24)
            Text(choice.title)
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
          }
          .padding(12)
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
#if os(iOS)
          .background(selected ? Color.accentColor.opacity(0.12) : Color(uiColor: .tertiarySystemFill),
            in: RoundedRectangle(cornerRadius: 6))
          .contentShape(Rectangle())
#elseif !os(visionOS)
          .background(selected ? Color.accentColor.opacity(0.12) : .clear,
            in: RoundedRectangle(cornerRadius: 6))
          .contentShape(Rectangle())
#endif
        }
#if os(visionOS)
        .buttonStyle(VisionSelectionButtonStyle(isSelected: selected))
#else
        .buttonStyle(.plain)
#endif
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
    .frame(maxWidth: 640, alignment: .leading)
  }
}
