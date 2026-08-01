import SwiftUI
import UIKit

struct ModeSelectionView: View {
  @EnvironmentObject private var appModel: AppModel
  @State private var showingAbout = false

  var body: some View {
    NavigationStack {
      ZStack {
        Color(.systemBackground)
          .ignoresSafeArea()

        VStack(spacing: 28) {
          Spacer(minLength: 20)

          borgVRLogo
            .frame(maxWidth: 280)
            .clipShape(RoundedRectangle(cornerRadius: 8))

          VStack(spacing: 8) {
            Text("BorgVR Mobile")
              .font(.largeTitle.weight(.bold))
              .multilineTextAlignment(.center)

            Text("Interaktive Visualisierung volumetrischer Datensätze auf iPhone und iPad")
              .font(.headline)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
          }

          VStack(spacing: 14) {
            Button {
              appModel.currentState = .selectData
            } label: {
              Label("Datensatz öffnen", systemImage: "folder")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button {
              appModel.currentState = .importData
            } label: {
              Label("Datensatz importieren", systemImage: "square.and.arrow.down")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
              appModel.currentState = .settings
            } label: {
              Label("Einstellungen", systemImage: "gearshape")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
              showingAbout = true
            } label: {
              Label("Info", systemImage: "info.circle")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
          }
          .controlSize(.large)
          .frame(maxWidth: 420)

          Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
      }
      .toolbar(.hidden, for: .navigationBar)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .sheet(isPresented: $showingAbout) {
      iOSAboutView()
    }
  }

  @ViewBuilder
  private var borgVRLogo: some View {
    if let url = Bundle.main.url(forResource: "borgvr", withExtension: "png"),
       let image = UIImage(contentsOfFile: url.path) {
      Image(uiImage: image)
        .resizable()
        .scaledToFit()
    } else {
      Image(systemName: "cube.transparent")
        .resizable()
        .scaledToFit()
        .foregroundStyle(.secondary)
        .frame(width: 120, height: 120)
    }
  }
}

private struct iOSAboutView: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          HStack(alignment: .center, spacing: 16) {
            aboutLogo
              .frame(width: 88, height: 88)
              .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 6) {
              Text("info_heading")
                .font(.title2.weight(.semibold))

              Text(
                String(
                  format: NSLocalizedString(
                    "info_version_format",
                    comment: "Version label with app version and build number"
                  ),
                  Bundle.main.appVersion,
                  Bundle.main.appBuild
                )
              )
              .font(.subheadline)
              .foregroundStyle(.secondary)
            }
          }

          Text("info_intro_body")
          Text("info_publications_intro")

          VStack(alignment: .leading, spacing: 8) {
            Link(
              "info_pub1_title",
              destination: URL(string: "https://ieeexplore.ieee.org/document/10771092")!
            )
            .font(.headline)

            Text("info_pub1_venue")

            Link(
              "info_pub2_title",
              destination: URL(string: "https://www.cgvis.de/publications.shtml#2025")!
            )
            .font(.headline)

            Text("info_pub2_venue")
          }

          Text("info_conclusion_body")

          HStack(spacing: 5) {
            Text("info_footer_copyright")
            Link(
              "info_footer_link",
              destination: URL(string: "https://www.cgvis.de")!
            )
          }
          .font(.footnote)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(.top, 10)
        }
        .padding(24)
        .textSelection(.enabled)
      }
      .navigationTitle("info_title")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("info_close_button") {
            dismiss()
          }
        }
      }
    }
  }

  @ViewBuilder
  private var aboutLogo: some View {
    if let url = Bundle.main.url(forResource: "borgvr", withExtension: "png"),
       let image = UIImage(contentsOfFile: url.path) {
      Image(uiImage: image)
        .resizable()
        .scaledToFit()
    } else {
      Image(systemName: "cube.transparent")
        .resizable()
        .scaledToFit()
        .foregroundStyle(.secondary)
    }
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
