import SwiftUI

struct DatasetProvenanceView: View {
  let entries: [BORGVRProvenanceEntry]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("dataset_info_provenance")
        .font(.caption)
        .foregroundStyle(.secondary)
      if entries.isEmpty {
        Text("dataset_info_no_provenance")
          .foregroundStyle(.secondary)
      } else {
        LazyVStack(alignment: .leading, spacing: 12) {
          ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            VStack(alignment: .leading, spacing: 4) {
              Text(entry.date.formatted(date: .abbreviated, time: .standard))
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(entry.date.formatted(.iso8601))
              Text(entry.text)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
    }
    .textSelection(.enabled)
  }
}
