import SwiftUI

struct DatasetInfoView: View {
  let dataset: AppModel.DatasetEntry?
  let metadata: BORGVRMetaData?
  var onClose: (() -> Void)?

  init(
    dataset: AppModel.DatasetEntry?,
    metadata: BORGVRMetaData? = nil,
    onClose: (() -> Void)? = nil
  ) {
    self.dataset = dataset
    self.metadata = metadata
    self.onClose = onClose
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if let dataset {
            infoRow(title: "dataset_info_name", value: dataset.description)
            infoRow(title: "dataset_info_source", value: sourceDescription(for: dataset.source))
            infoRow(title: "dataset_info_unique_id", value: dataset.uniqueId)
            if let physicalSize = metadata.flatMap({
              PhysicalSizeFormatter.dimensions(for: $0)
            }) {
              infoRow(title: "dataset_info_physical_size", value: physicalSize)
            }
            alternativeSourcesRow(for: dataset)
            infoRow(
              title: "dataset_info_metadata",
              value: dataset.metadataSummary ?? String(localized: "dataset_info_no_metadata")
            )
          } else {
            ContentUnavailableView(
              "dataset_info_unavailable_title",
              systemImage: "info.circle",
              description: Text("dataset_info_unavailable_message")
            )
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
      }
      .navigationTitle("dataset_info_title")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button {
            onClose?()
          } label: {
            Label("Close", systemImage: "xmark")
          }
        }
      }
    }
  }

  private func infoRow(title: LocalizedStringKey, value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value.isEmpty ? String(localized: "dataset_info_empty_value") : value)
        .font(.body)
        .textSelection(.enabled)
    }
  }

  private func sourceDescription(for source: AppModel.DatasetSource) -> String {
    switch source {
      case .local:
        return String(localized: "dataset_source_local")
      case .builtIn:
        return String(localized: "dataset_source_built_in")
      case let .remote(address, port, _):
        return String(format: String(localized: "dataset_source_remote_format"), address, port)
    }
  }

  private func alternativeSources(for dataset: AppModel.DatasetEntry) -> [DatasetOrigin] {
    let activeOrigin: DatasetOrigin?
    switch dataset.source {
      case let .remote(address, port, password):
        activeOrigin = DatasetOrigin(address: address, port: port, password: password)
      case .local, .builtIn:
        activeOrigin = nil
    }

    return DatasetOriginCatalog.shared.origins(for: dataset.uniqueId).filter {
      $0.identityKey != activeOrigin?.identityKey
    }
  }

  private func alternativeSourcesRow(for dataset: AppModel.DatasetEntry) -> some View {
    let alternatives = alternativeSources(for: dataset)
    let visibleAlternatives = Array(alternatives.prefix(alternatives.count > 3 ? 2 : 3))

    return VStack(alignment: .leading, spacing: 6) {
      Text("dataset_info_alternative_sources")
        .font(.caption)
        .foregroundStyle(.secondary)

      if alternatives.isEmpty {
        Text("dataset_info_no_alternative_sources")
          .font(.body)
          .foregroundStyle(.secondary)
      } else {
        ForEach(visibleAlternatives, id: \.identityKey) { origin in
          HStack(spacing: 8) {
            Text(originDescription(origin))
              .textSelection(.enabled)

            if !origin.password.isEmpty {
              sourceStatusIcon(
                systemName: "key.fill",
                label: String(localized: "dataset_info_password_protected")
              )
            }

            if !DatasetOriginCatalog.shared.sharingAllowed(for: origin) {
              sourceStatusIcon(
                systemName: "eye.slash.fill",
                label: String(localized: "dataset_info_private_source")
              )
            }
          }
        }

        if alternatives.count > 3 {
          Text(
            String(
              format: String(localized: "dataset_info_more_sources_format"),
              String(alternatives.count - 2)
            )
          )
          .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func sourceStatusIcon(systemName: String, label: String) -> some View {
    Image(systemName: systemName)
      .font(.caption)
      .foregroundStyle(.secondary)
      .accessibilityLabel(label)
      .help(label)
  }

  private func originDescription(_ origin: DatasetOrigin) -> String {
    let address = origin.address.contains(":") && !origin.address.hasPrefix("[")
      ? "[\(origin.address)]"
      : origin.address
    return "\(address):\(origin.port)"
  }
}
