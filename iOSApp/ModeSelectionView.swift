import SwiftUI
import UIKit

struct ModeSelectionView: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var appSettings: AppSettings
  @EnvironmentObject private var serverController: BackgroundServerController
  @State private var showingAbout = false

  var body: some View {
    NavigationStack {
      GeometryReader { proxy in
        let layout = AdaptiveLayout(
          size: proxy.size,
          safeAreaInsets: proxy.safeAreaInsets,
          horizontalSizeClass: horizontalSizeClass,
          verticalSizeClass: verticalSizeClass
        )

        ZStack {
          Color(.systemBackground)
            .ignoresSafeArea()

          content(for: layout)
        }
      }
      .toolbar(.hidden, for: .navigationBar)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .sheet(isPresented: $showingAbout) {
      iOSAboutView()
    }
  }

  @ViewBuilder
  private func content(for layout: AdaptiveLayout) -> some View {
    VStack(spacing: 0) {
      visualHeader(for: layout)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
        .ignoresSafeArea(edges: [.top, .horizontal])

      actionPanel(for: layout)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func visualHeader(for layout: AdaptiveLayout) -> some View {
    let isCompactPortrait = !layout.isLandscape && !layout.isRegularWidth

    return GeometryReader { proxy in
      ZStack(alignment: isCompactPortrait ? .bottom : .bottomLeading) {
        borgVRArtwork
          .scaledToFill()
          .frame(width: proxy.size.width, height: proxy.size.height)
          .clipped()

        Color.black.opacity(0.38)

        titleBlock(
          horizontalAlignment: isCompactPortrait ? .center : .leading,
          multilineAlignment: isCompactPortrait ? .center : .leading
        )
          .frame(
            maxWidth: isCompactPortrait ? .infinity : 760,
            alignment: isCompactPortrait ? .center : .leading
          )
          .padding(.horizontal, isCompactPortrait ? 24 : 40)
          .padding(.bottom, isCompactPortrait ? 24 : 30)
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
    .accessibilityElement(children: .contain)
  }

  private func titleBlock(
    horizontalAlignment: HorizontalAlignment,
    multilineAlignment: TextAlignment
  ) -> some View {
    VStack(alignment: horizontalAlignment, spacing: 8) {
      Text("BorgVR Mobile")
        .font(.largeTitle.weight(.bold))
        .foregroundStyle(.white)
        .multilineTextAlignment(multilineAlignment)

      Text("Interactive visualization of volumetric datasets on iPhone and iPad")
        .font(.headline)
        .foregroundStyle(.white.opacity(0.86))
        .multilineTextAlignment(multilineAlignment)
    }
  }

  private func actionPanel(for layout: AdaptiveLayout) -> some View {
    VStack(spacing: 14) {
      actionGrid(columnCount: actionColumnCount(for: layout))

      if appSettings.enableDatasetServer {
        Divider()

        ViewThatFits(in: .horizontal) {
          HStack(spacing: 20) {
            serverStatus
            serverButton
              .frame(maxWidth: 360)
          }

          VStack(spacing: 12) {
            serverStatus
            serverButton
          }
        }
      }
    }
    .frame(maxWidth: 1120)
    .padding(.horizontal, layout.isRegularWidth ? 40 : 20)
    .padding(.top, 18)
    .padding(.bottom, max(layout.safeAreaInsets.bottom, 18))
    .frame(maxWidth: .infinity)
    .background(Color(.systemBackground))
    .overlay(alignment: .top) {
      Rectangle()
        .fill(Color.accentColor)
        .frame(height: 3)
        .accessibilityHidden(true)
    }
  }

  private func actionGrid(columnCount: Int) -> some View {
    LazyVGrid(
      columns: Array(
        repeating: GridItem(.flexible(minimum: 120), spacing: 12),
        count: columnCount
      ),
      spacing: 12
    ) {
      Button {
        appModel.currentState = .selectData
      } label: {
        Label("Open dataset", systemImage: "folder")
          .frame(maxWidth: .infinity, minHeight: 32)
      }
      .buttonStyle(.borderedProminent)

      Button {
        appModel.currentState = .importData
      } label: {
        Label("Import dataset", systemImage: "square.and.arrow.down")
          .frame(maxWidth: .infinity, minHeight: 32)
      }
      .buttonStyle(.bordered)

      Button {
        appModel.currentState = .settings
      } label: {
        Label("Settings", systemImage: "gearshape")
          .frame(maxWidth: .infinity, minHeight: 32)
      }
      .buttonStyle(.bordered)

      Button {
        showingAbout = true
      } label: {
        Label("Info", systemImage: "info.circle")
          .frame(maxWidth: .infinity, minHeight: 32)
      }
      .buttonStyle(.bordered)
    }
    .controlSize(.large)
  }

  private func actionColumnCount(for layout: AdaptiveLayout) -> Int {
    switch layout.modeSelectionStyle {
      case .regularLandscape:
        4
      case .compactLandscape:
        2
      case .portrait:
        layout.isRegularWidth ? 2 : 1
    }
  }

  private var serverButton: some View {
    Button {
      if serverController.isRunning {
        serverController.stop()
      } else {
        serverController.start(using: appSettings)
      }
    } label: {
      Label(
        serverController.isRunning ? "Stop background server" : "Start background server",
        systemImage: serverController.isRunning ? "stop.circle" : "play.circle"
      )
      .frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered)
  }

  private var serverStatus: some View {
    VStack(spacing: 6) {
      Label(
        serverController.isRunning ? "Background server running" : "Background server stopped",
        systemImage: serverController.isRunning ? "checkmark.circle.fill" : "circle"
      )
      .foregroundStyle(serverController.isRunning ? .green : .secondary)

      Text(serverController.statusText)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .lineLimit(3)
    }
    .frame(maxWidth: 420)
  }

  @ViewBuilder
  private var borgVRArtwork: some View {
    if let url = Bundle.main.url(forResource: "borgvr", withExtension: "png"),
       let image = UIImage(contentsOfFile: url.path) {
      Image(uiImage: image)
        .resizable()
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
          Button {
            dismiss()
          } label: {
            Label("info_close_button", systemImage: "xmark")
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
