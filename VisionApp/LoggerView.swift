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
      Text("Application Log")
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
        Button("Clear Log") {
          logText = ""
        }

        Button("Export Log") {
          isExporting = true
        }

        Spacer()

        Picker("Log Level", selection: $selectedLogLevel) {
          Text("All Messages").tag(LogLevel.dev)
          Text("Progress and up").tag(LogLevel.progress)
          Text("Info and up").tag(LogLevel.info)
          Text("Warnings and up").tag(LogLevel.warning)
          Text("Only Errors").tag(LogLevel.error)
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
      defaultFilename: "LogOutput"
    ) { result in
      switch result {
        case .success(let url):
          logger.dev("Log saved to \(url)")
        case .failure(let error):
          logger.error("Failed to save log: \(error.localizedDescription)")
      }
    }
  }
}
