import SwiftUI
import UniformTypeIdentifiers

struct ImportDetailsView: View {
  @Environment(RuntimeAppModel.self) private var runtimeAppModel
  @Environment(\.dismiss) private var dismiss
  @State private var text = ""
  @State private var isExporting = false
  @State private var exportError: String?

  private var logger: GUILogger { runtimeAppModel.importLogger }

  var body: some View {
    VStack(spacing: 16) {
      Text(String(localized: "Live Details", table: "ImportMessages"))
        .font(.title2.bold())
      TextEditor(text: $text)
        .font(.system(.body, design: .monospaced))
        .scrollContentBackground(.hidden)
      HStack(spacing: 16) {
        Button { logger.clear() } label: {
          Label("converter_clear_output", systemImage: "eraser")
        }
        Button { isExporting = true } label: {
          Label("converter_export_output", systemImage: "square.and.arrow.up")
        }
        Spacer()
        Button { dismiss() } label: { Label("Done", systemImage: "checkmark") }
      }
    }
    .padding(24)
    .frame(minWidth: 700, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
    .onAppear { logger.setLogBinding($text) }
    .fileExporter(isPresented: $isExporting, document: TextFileDocument(text: text),
      contentType: .plainText,
      defaultFilename: String(localized: "converter_default_export_filename")) { result in
      switch result {
        case .success(let url):
          logger.info(String(format: String(localized: "converter_log_saved_to_url"), url.path))
        case .failure(let error):
          let message = String(format: String(localized: "converter_failed_to_save_log"), error.localizedDescription)
          logger.error(message)
          exportError = message
      }
    }
    .alert("Error", isPresented: Binding(get: { exportError != nil },
      set: { if !$0 { exportError = nil } })) {
      Button("OK", role: .cancel) {}
    } message: { Text(exportError ?? "") }
  }
}
