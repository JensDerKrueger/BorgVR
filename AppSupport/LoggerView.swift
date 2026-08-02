import SwiftUI

struct LoggerView: View {
  let logger: GUILogger
  @State private var text = ""
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      TextEditor(text: $text)
        .font(.system(.body, design: .monospaced))
        .padding()
        .navigationTitle("Log")
        .toolbar {
          Button("Fertig") { dismiss() }
        }
        .onAppear {
          logger.setLogBinding($text)
        }
    }
  }
}
