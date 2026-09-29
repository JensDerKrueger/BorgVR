import SwiftUI

struct ScriptLogView: View {
  @EnvironmentObject private var scriptRunner: BorgVRScriptRunner

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: scriptRunner.isRunning ? "play.circle.fill" : "checkmark.circle")
          .foregroundStyle(scriptRunner.isRunning ? .blue : .secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text(scriptRunner.scriptURL?.lastPathComponent ?? String(localized: "Script Log"))
            .font(.headline)
            .lineLimit(1)
          Text(scriptRunner.statusText)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          scriptRunner.clearScriptExecutionLog()
        } label: {
          Label("Clear Script Log", systemImage: "trash")
        }
        .labelStyle(.iconOnly)
        .help("Clear Script Log")

        Button {
          scriptRunner.stopScript()
        } label: {
          Label("Stop Script", systemImage: "stop.fill")
        }
        .labelStyle(.iconOnly)
        .help("Stop Script")
        .disabled(!scriptRunner.isRunning)
      }
      .padding(12)

      Divider()

      ScrollViewReader { proxy in
        ScrollView {
          Text(
            scriptRunner.scriptLogText.isEmpty
              ? String(localized: "No script output yet.")
              : scriptRunner.scriptLogText
          )
          .font(.system(.body, design: .monospaced))
          .foregroundStyle(scriptRunner.scriptLogText.isEmpty ? .secondary : .primary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(12)

          Color.clear
            .frame(height: 1)
            .id("script-log-bottom")
        }
        .onChange(of: scriptRunner.scriptLogText) { _, _ in
          proxy.scrollTo("script-log-bottom", anchor: .bottom)
        }
      }

      if let progress = scriptRunner.scriptProgressValue {
        Divider()
        HStack(spacing: 12) {
          Text(scriptRunner.scriptProgressText)
            .lineLimit(1)
          ProgressView(value: progress)
            .frame(maxWidth: .infinity)
          Text(progress, format: .percent.precision(.fractionLength(0)))
            .monospacedDigit()
            .frame(width: 44, alignment: .trailing)
        }
        .font(.caption)
        .padding(12)
      }
    }
    .frame(minWidth: 620, minHeight: 360)
  }
}
