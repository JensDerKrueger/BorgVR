import SwiftUI
import UniformTypeIdentifiers

struct LoggerView: View {
  let logger: GUILogger

  @State private var logText: String = ""
  @State private var progressText: String = ""
  @State private var progressValue: Double = 0.0

  @State private var isExporting = false
  @State private var exportURL: URL?

  @State private var selectedLogLevel: LogLevel = .dev

  var body: some View {
    VStack(spacing: 20) {
      Text("logger_title")
        .font(.title)
        .bold()

      HStack {
        Text(progressText)
        ProgressView(value: progressValue)
          .padding()
      }

      TextEditor(text: $logText)
        .border(Color.gray, width: 1)
        .font(.system(.body, design: .monospaced))

      HStack(spacing: 16) {
        Button("logger_clear_log_button") {
          logText = ""
        }

        Button("logger_export_log_button") {
          isExporting = true
        }

        Spacer()

        Picker("logger_log_level_label", selection: $selectedLogLevel) {
          Text("logger_log_level_all").tag(LogLevel.dev)
          Text("logger_log_level_progress").tag(LogLevel.progress)
          Text("logger_log_level_info").tag(LogLevel.info)
          Text("logger_log_level_warning").tag(LogLevel.warning)
          Text("logger_log_level_error").tag(LogLevel.error)
        }
        .pickerStyle(SegmentedPickerStyle())
        .frame(maxWidth: 750)
      }
    }
    .padding()
    .onAppear {
      logger.setLogBinding($logText)
      logger.setProgressBinding($progressText, $progressValue)
      logger.setMinimumLogLevel(selectedLogLevel)
    }
    .onChange(of: selectedLogLevel) { _, newLevel in
      logger.setMinimumLogLevel(newLevel)
    }
    .fileExporter(
      isPresented: $isExporting,
      document: TextFileDocument(text: logText),
      contentType: .plainText,
      defaultFilename: NSLocalizedString(
        "logger_default_export_filename",
        comment: "Default filename for exported log"
      )
    ) { result in
      switch result {
        case .success(let url):
          logger.dev(
            String(
              format: NSLocalizedString(
                "logger_log_saved_to_url",
                comment: "Log saved to URL"
              ),
              url.path
            )
          )
        case .failure(let error):
          logger.error(
            String(
              format: NSLocalizedString(
                "logger_failed_to_save_log",
                comment: "Failed to save log"
              ),
              error.localizedDescription
            )
          )
      }
    }
  }
}
