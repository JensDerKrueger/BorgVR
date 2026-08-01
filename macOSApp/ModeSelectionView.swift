import SwiftUI

struct ModeSelectionView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var storedAppModel: StoredAppModel
  @EnvironmentObject private var serverController: BackgroundServerController
  @State private var showingAbout = false

  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 26) {
        Spacer()

        Image("borgvr")
          .resizable()
          .scaledToFit()
          .frame(width: 188, height: 188)
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 10)

        VStack(alignment: .leading, spacing: 8) {
          Text("BorgVR macOS")
            .font(.system(size: 46, weight: .bold))

          Text("modeselection_tagline")
            .font(.title3)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

          Text(
            String(
              format: NSLocalizedString(
                "modeselection_version_format",
                comment: "Version label with app version and build number"
              ),
              Bundle.main.appVersion,
              Bundle.main.appBuild
            )
          )
          .font(.callout.weight(.medium))
          .foregroundStyle(.tertiary)
        }

        serverStatus

        Spacer()

        footer
      }
      .padding(44)
      .frame(width: 430, alignment: .leading)
      .background(Color(nsColor: .underPageBackgroundColor))

      VStack(spacing: 14) {
        Spacer()

        commandButton("modeselection_open_dataset", systemImage: "folder") {
          appModel.currentState = .selectData
        }

        commandButton("modeselection_import", systemImage: "square.and.arrow.down") {
          appModel.currentState = .importData
        }

        commandButton("modeselection_settings", systemImage: "gearshape") {
          appModel.currentState = .settings
        }

        Divider()
          .frame(maxWidth: 420)
          .padding(.vertical, 8)

        commandButton(
          serverController.isRunning ? "modeselection_stop_background_server" : "modeselection_start_background_server",
          systemImage: serverController.isRunning ? "stop.circle" : "play.circle"
        ) {
          if serverController.isRunning {
            serverController.stop()
          } else {
            serverController.start(using: storedAppModel)
          }
        }

        Button {
          showingAbout = true
        } label: {
          Label("modeselection_about", systemImage: "info.circle")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .frame(maxWidth: 420)

        Spacer()
      }
      .padding(44)
      .frame(maxWidth: .infinity)
    }
    .sheet(isPresented: $showingAbout) {
      MacAboutView()
        .frame(minWidth: 720, idealWidth: 820, minHeight: 460)
    }
  }

  private var serverStatus: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(
        serverController.isRunning ? "modeselection_server_running" : "modeselection_server_stopped",
        systemImage: serverController.isRunning ? "checkmark.circle.fill" : "circle"
      )
      .foregroundStyle(serverController.isRunning ? .green : .secondary)

      Text(serverController.statusText)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(3)
    }
  }

  private var footer: some View {
    HStack(spacing: 5) {
      Text("modeselection_footer_years")
      Link(
        "modeselection_footer_cgvis",
        destination: URL(string: "https://www.cgvis.de")!
      )
    }
    .font(.footnote)
    .foregroundStyle(.secondary)
  }

  private func commandButton(
    _ title: LocalizedStringKey,
    systemImage: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
    .buttonStyle(.borderedProminent)
    .controlSize(.large)
    .frame(maxWidth: 420)
  }
}

private struct MacAboutView: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .center, spacing: 18) {
        Image("borgvr")
          .resizable()
          .scaledToFit()
          .frame(width: 96, height: 96)
          .clipShape(RoundedRectangle(cornerRadius: 8))

        VStack(alignment: .leading, spacing: 6) {
          Text("info_heading")
            .font(.title2.weight(.semibold))

          Text(
            String(
              format: NSLocalizedString(
                "modeselection_version_format",
                comment: "Version label with app version and build number"
              ),
              Bundle.main.appVersion,
              Bundle.main.appBuild
            )
          )
          .foregroundStyle(.secondary)
        }

        Spacer()
      }

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          Text("info_paragraph_intro")
          Text("info_paragraph_papers")

          VStack(alignment: .leading, spacing: 8) {
            Link(
              "info_paper1_title",
              destination: URL(string: "https://ieeexplore.ieee.org/document/10771092")!
            )
            .font(.headline)

            Text("info_paper1_venue")

            Link(
              "info_paper2_title",
              destination: URL(string: "https://www.cgvis.de/publications.shtml#2025")!
            )
            .font(.headline)

            Text("info_paper2_venue")
          }

          Text("info_paragraph_future")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
      }

      HStack {
        HStack(spacing: 5) {
          Text("info_footer_years")
          Link(
            "info_footer_cgvis",
            destination: URL(string: "https://www.cgvis.de")!
          )
        }
        .font(.footnote)
        .foregroundStyle(.secondary)

        Spacer()

        Button {
          dismiss()
        } label: {
          Label("info_button_close", systemImage: "xmark.circle")
        }
        .keyboardShortcut(.cancelAction)
      }
    }
    .padding(28)
  }
}

private extension Bundle {
  var appVersion: String {
    object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
  }

  var appBuild: String {
    object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
  }
}
