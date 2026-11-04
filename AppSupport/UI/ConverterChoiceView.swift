import SwiftUI

enum VolumeImportKind: String, CaseIterable, Identifiable {
  case volumeFile
  case dicomDirectory
  case dicomFusion
  case imageSequence

  var id: Self { self }

  var title: LocalizedStringKey {
    switch self {
      case .volumeFile: "Volume File"
      case .dicomDirectory: "DICOM Series"
      case .dicomFusion: "DICOM Fusion"
      case .imageSequence: "Image Sequence"
    }
  }

  var systemImage: String {
    switch self {
      case .volumeFile: "doc"
      case .dicomDirectory: "cross.case"
      case .dicomFusion: "square.3.layers.3d"
      case .imageSequence: "photo.on.rectangle.angled"
    }
  }
}

struct ConverterChoiceItem: Identifiable {
  let id: String
  let title: LocalizedStringKey
  let systemImage: String
  let action: () -> Void
}

struct ConverterVolumeFormatList: View {
  var includesNativeBorgVR = false

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
      Text("Supported volume formats")
        .font(.subheadline.weight(.semibold))
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

struct ConverterWizardHeader: View {
  let title: LocalizedStringKey
  let step: Int
  let total: Int

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
        .font(.title.bold())
        .fixedSize(horizontal: false, vertical: true)
        .padding()
      Text(String(format: NSLocalizedString("converter_step_of_total_format", comment: ""), step, total))
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
  let total: Int
  let choices: [ConverterChoiceItem]
  let selectedID: String?
  var canGoBack = true
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
      HStack {
        Spacer()
        Button(action: onBack) { Label("converter_button_back", systemImage: "chevron.backward") }
          .disabled(!canGoBack)
        Button(action: onNext) { Label("converter_nav_next", systemImage: "chevron.forward") }
          .disabled(selectedID == nil)
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
        Button(action: choice.action) {
          HStack(spacing: 12) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
              .foregroundStyle(selected ? Color.accentColor : .secondary)
            Image(systemName: choice.systemImage)
              .foregroundStyle(.tint)
              .frame(width: 24)
            Text(choice.title)
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
          }
          .padding(12)
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          .background(selected ? Color.accentColor.opacity(0.12) : .clear,
            in: RoundedRectangle(cornerRadius: 6))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
    .frame(maxWidth: 640, alignment: .leading)
  }
}
