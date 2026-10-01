import SwiftUI
import AppKit

struct ModeSelectionView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var storedAppModel: StoredAppModel
  @EnvironmentObject private var serverController: BackgroundServerController
  @EnvironmentObject private var scriptRunner: BorgVRScriptRunner
  @State private var showingAbout = false
  @State private var scriptDropIsTargeted = false

  var body: some View {
    GeometryReader { proxy in
      let panelWidth = controlPanelWidth(for: proxy.size.width)

      HStack(spacing: 0) {
        mandelbulbArtwork
          .scaledToFill()
          .frame(
            width: max(proxy.size.width - panelWidth, 0),
            height: proxy.size.height
          )
          .clipped()
          .contentShape(Rectangle())
          .overlay {
            if scriptDropIsTargeted {
              ZStack {
                Color.black.opacity(0.42)

                VStack(spacing: 14) {
                  Image(systemName: "play.circle.fill")
                    .font(.system(size: 54, weight: .semibold))
                  Text("modeselection_drop_script")
                    .font(.title2.weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(28)
              }
              .transition(.opacity)
            }
          }
          .dropDestination(for: URL.self) { urls, _ in
            guard let scriptURL = urls.first(where: {
              $0.pathExtension.caseInsensitiveCompare("gsc") == .orderedSame
            }) else {
              return false
            }
            scriptRunner.runScript(at: scriptURL)
            return true
          } isTargeted: { isTargeted in
            withAnimation(.easeInOut(duration: 0.15)) {
              scriptDropIsTargeted = isTargeted
            }
          }
          .accessibilityHidden(true)

        controlPanel
          .frame(width: panelWidth)
          .frame(maxHeight: .infinity)
          .background(.regularMaterial)
          .overlay(alignment: .leading) {
            Rectangle()
              .fill(Color(nsColor: .separatorColor))
              .frame(width: 1)
          }
      }
    }
    .sheet(isPresented: $showingAbout) {
      MacAboutView()
        .frame(minWidth: 720, idealWidth: 820, minHeight: 460)
    }
  }

  private var controlPanel: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 16) {
        Image("borgvr")
          .resizable()
          .scaledToFill()
          .frame(width: 72, height: 72)
          .clipShape(RoundedRectangle(cornerRadius: 12))
          .overlay {
            RoundedRectangle(cornerRadius: 12)
              .stroke(Color.primary.opacity(0.14), lineWidth: 1)
          }
          .shadow(color: .black.opacity(0.18), radius: 7, y: 3)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 7) {
          Text("BorgVR")
            .font(.system(size: 44, weight: .bold))

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
      }

      Spacer(minLength: 32)

      VStack(spacing: 14) {
        commandButton("modeselection_open_dataset", systemImage: "folder") {
          appModel.navigationState = .selectData
        }

        commandButton("modeselection_import", systemImage: "square.and.arrow.down") {
          appModel.navigationState = .importData
        }

        commandButton("modeselection_settings", systemImage: "gearshape") {
          appModel.navigationState = .settings
        }

        if storedAppModel.enableDatasetServer {
          Divider()
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
        }

        commandButton("modeselection_about", systemImage: "info.circle") {
          showingAbout = true
        }
      }

      Spacer(minLength: 32)

      VStack(alignment: .leading, spacing: 22) {
        if storedAppModel.enableDatasetServer {
          serverStatus
        }

        footer
      }
    }
    .padding(.horizontal, 42)
    .padding(.vertical, 38)
  }

  private func controlPanelWidth(for windowWidth: CGFloat) -> CGFloat {
    min(max(windowWidth * 0.36, 380), 460)
  }

  @ViewBuilder
  private var mandelbulbArtwork: some View {
    if let url = Bundle.main.url(forResource: "mandelbulb-background", withExtension: "jpg"),
       let image = NSImage(contentsOf: url) {
      Image(nsImage: image)
        .resizable()
    } else {
      Image("borgvr")
        .resizable()
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
    .buttonStyle(.bordered)
    .controlSize(.large)
    .frame(maxWidth: .infinity)
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
