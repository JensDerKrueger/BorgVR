import SwiftUI

struct TransferFunctionEditorView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var renderingParameters: RenderingParameters
  @EnvironmentObject private var sharePlay: SharePlayCoordinator
  var usesPanelBackground = true
  var onClose: (() -> Void)?
  @State private var lastPaintPoint: CGPoint?

  @ViewBuilder
  var body: some View {
    if usesPanelBackground {
      editorContent
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    } else {
      editorContent
    }
  }

  private var editorContent: some View {
    VStack(spacing: 10) {
      GeometryReader { geometry in
        Canvas { context, size in
          let rect = CGRect(origin: .zero, size: size)
          renderingParameters.transferFunction.drawCheckerboard(in: context, rect: rect)
          renderingParameters.transferFunction.drawRibbon(in: context, rect: rect.insetBy(dx: 0, dy: size.height * 0.38))
          renderingParameters.transferFunction.drawGrid(in: context, rect: rect)
          renderingParameters.transferFunction.drawCurves(in: context, rect: rect)
        }
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { value in
              paint(at: value.location, in: geometry.size)
            }
            .onEnded { _ in
              lastPaintPoint = nil
              sharePlay.flushSynchronization()
            }
        )
      }
      .frame(height: 150)

      HStack {
        channelButton(
          "R",
          color: .red,
          help: "tf_editor_red_channel_help",
          isSelected: renderingParameters.transferEditing.red
        ) {
          renderingParameters.transferEditing.red.toggle()
          sharePlay.synchronize(kind: .stateOnly)
        }
        channelButton(
          "G",
          color: .green,
          help: "tf_editor_green_channel_help",
          isSelected: renderingParameters.transferEditing.green
        ) {
          renderingParameters.transferEditing.green.toggle()
          sharePlay.synchronize(kind: .stateOnly)
        }
        channelButton(
          "B",
          color: .blue,
          help: "tf_editor_blue_channel_help",
          isSelected: renderingParameters.transferEditing.blue
        ) {
          renderingParameters.transferEditing.blue.toggle()
          sharePlay.synchronize(kind: .stateOnly)
        }
        channelButton(
          "A",
          color: .white,
          help: "tf_editor_alpha_channel_help",
          isSelected: renderingParameters.transferEditing.opacity
        ) {
          renderingParameters.transferEditing.opacity.toggle()
          sharePlay.synchronize(kind: .stateOnly)
        }

        Spacer()

        Button {
          saveTransferFunction()
        } label: {
          Image(systemName: "square.and.arrow.down")
        }
        .disabled(transferFunctionFileURL == nil)
        .help("tf_editor_save_help")
        .accessibilityLabel("tf_editor_save")

        Button {
          loadTransferFunction()
        } label: {
          Image(systemName: "square.and.arrow.up")
        }
        .disabled(transferFunctionFileURL == nil)
        .help("tf_editor_load_help")
        .accessibilityLabel("tf_editor_load")

        Button {
          renderingParameters.objectWillChange.send()
          renderingParameters.transferFunction.slicingPreset()
          renderingParameters.renderMode = .transferFunction1D
          sharePlay.synchronize(kind: .full)
        } label: {
          Image(systemName: "square.split.2x1")
        }
        .help("Slicing Preset")
        .accessibilityLabel("Slicing Preset")

        Button {
          renderingParameters.objectWillChange.send()
          renderingParameters.transferFunction.reset()
          sharePlay.synchronize(kind: .full)
        } label: {
          Image(systemName: "arrow.counterclockwise")
        }
        .help("Reset")
        .accessibilityLabel("Reset")

        Button {
          onClose?()
        } label: {
          Image(systemName: "checkmark")
        }
        .help("Fertig")
        .accessibilityLabel("Fertig")
      }
    }
  }

  private func channelButton(
    _ title: String,
    color: Color,
    help: LocalizedStringKey,
    isSelected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Text(title)
        .font(.headline)
        .monospaced()
        .frame(width: 28, height: 28)
    }
    .buttonStyle(.borderedProminent)
    .tint(isSelected ? color : .gray)
    .help(help)
    .accessibilityLabel(help)
  }

  private func paint(at point: CGPoint, in size: CGSize) {
    guard size.width > 0, size.height > 0 else { return }

    let current = normalizedPaintPoint(point, in: size)
    let channels = selectedChannels
    renderingParameters.objectWillChange.send()

    if let lastPaintPoint {
      let previous = normalizedPaintPoint(lastPaintPoint, in: size)
      renderingParameters.transferFunction.paintLine(
        from: Float(previous.x),
        startValue: Float(previous.y),
        to: Float(current.x),
        endValue: Float(current.y),
        channels: channels,
        radius: 1
      )
    } else {
      renderingParameters.transferFunction.paintValue(
        at: Float(current.x),
        value: Float(current.y),
        channels: channels,
        radius: 1
      )
    }

    lastPaintPoint = point
    sharePlay.synchronize(kind: .full)
  }

  private func normalizedPaintPoint(_ point: CGPoint, in size: CGSize) -> CGPoint {
    CGPoint(
      x: min(1, max(0, point.x / size.width)),
      y: min(1, max(0, 1 - point.y / size.height))
    )
  }

  private var selectedChannels: [Int] {
    var channels: [Int] = []
    if renderingParameters.transferEditing.red { channels.append(0) }
    if renderingParameters.transferEditing.green { channels.append(1) }
    if renderingParameters.transferEditing.blue { channels.append(2) }
    if renderingParameters.transferEditing.opacity { channels.append(3) }
    return channels.isEmpty ? [3] : channels
  }

  private var transferFunctionFileURL: URL? {
    guard appModel.activeDataset?.source == .local,
          let identifier = appModel.activeDataset?.identifier else {
      return nil
    }
    return URL(fileURLWithPath: identifier).deletingPathExtension().appendingPathExtension("tf1d")
  }

  private func saveTransferFunction() {
    guard let fileURL = transferFunctionFileURL else { return }
    do {
      try renderingParameters.transferFunction.save(to: fileURL)
      appModel.logger.info(
        String(localized: "tf_editor_save_success") + " \(fileURL.lastPathComponent)"
      )
    } catch {
      appModel.logger.warning(
        String(localized: "tf_editor_save_failed") + " \(error.localizedDescription)"
      )
    }
  }

  private func loadTransferFunction() {
    guard let fileURL = transferFunctionFileURL else { return }
    do {
      renderingParameters.objectWillChange.send()
      try renderingParameters.transferFunction.load(from: fileURL)
      sharePlay.synchronize(kind: .full)
      appModel.logger.info(
        String(localized: "tf_editor_load_success") + " \(fileURL.lastPathComponent)"
      )
    } catch {
      appModel.logger.warning(
        String(localized: "tf_editor_load_failed") + " \(error.localizedDescription)"
      )
    }
  }
}
