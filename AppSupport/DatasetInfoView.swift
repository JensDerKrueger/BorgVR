import SwiftUI

struct DatasetInfoView: View {
  let dataset: AppModel.DatasetEntry?
  var onClose: (() -> Void)?

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if let dataset {
            infoRow(title: "dataset_info_name", value: dataset.description)
            infoRow(title: "dataset_info_source", value: sourceDescription(for: dataset.source))
            infoRow(title: "dataset_info_unique_id", value: dataset.uniqueId)
            infoRow(title: "dataset_info_identifier", value: dataset.identifier)
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
          Button("Schließen") {
            onClose?()
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
      case let .remote(address, port):
        return String(format: String(localized: "dataset_source_remote_format"), address, port)
    }
  }
}
