import SwiftUI

struct TransferFunctionEditorView: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var renderingParameters: RenderingParameters
  @EnvironmentObject private var sharePlay: SharePlayCoordinator
  var usesPanelBackground = true
  var usesFlexibleCanvasHeight = false
  var catalogDirectoryURLs: [URL] = []
  var onMutation: (() -> Void)?
  var onClose: (() -> Void)?
  @State private var lastPaintPoint: CGPoint?
  @State private var previewRefreshToken: UInt64 = 0
  @State private var transferFunctionCatalog: [TransferFunctionCatalogEntry] = []
  @State private var saveDescription = ""
  @State private var showingSaveDescriptionPrompt = false

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
      if renderingParameters.componentCount > 1 {
        dataChannelPicker
      }

      if usesFlexibleCanvasHeight {
        transferFunctionCanvas
          .frame(minHeight: 150, maxHeight: .infinity)
      } else {
        transferFunctionCanvas
          .frame(height: 150)
      }

      transferFunctionToolbar
    }
    .onAppear(perform: refreshTransferFunctionCatalog)
    .onChange(of: catalogDirectoryURLs) {
      refreshTransferFunctionCatalog()
    }
    .onReceive(NotificationCenter.default.publisher(
      for: TransferFunctionCatalog.didChangeNotification
    )) { _ in
      refreshTransferFunctionCatalog()
    }
    .alert("tf_save_dialog_title", isPresented: $showingSaveDescriptionPrompt) {
      TextField("tf_save_dialog_description_placeholder", text: $saveDescription)
      Button("tf_save_dialog_save_button") {
        saveTransferFunction(description: saveDescription)
      }
      Button("tf_save_dialog_cancel_button", role: .cancel) {}
    } message: {
      Text("tf_save_dialog_message")
    }
  }

  private var dataChannelPicker: some View {
    Picker(
      "tf_data_channel",
      selection: dataChannelSelection
    ) {
      ForEach(0..<renderingParameters.componentCount, id: \.self) { channel in
        Text(String(format: String(localized: "tf_data_channel_format"), channel + 1))
          .tag(channel)
      }
    }
    .pickerStyle(.segmented)
    .onChange(of: renderingParameters.selectedTransferFunctionChannel) {
      lastPaintPoint = nil
      refreshTransferFunctionCatalog()
    }
  }

  private var dataChannelSelection: Binding<Int> {
    #if os(macOS)
    // AppKit's segmented-control callback runs inside SwiftUI's UpdateGroup.
    // Publish the model change after that callback, not during the view update.
    Binding(
      get: { renderingParameters.selectedTransferFunctionChannel },
      set: { channel in
        Task { @MainActor in
          guard (0..<renderingParameters.componentCount).contains(channel),
                renderingParameters.selectedTransferFunctionChannel != channel else { return }
          renderingParameters.selectedTransferFunctionChannel = channel
        }
      }
    )
    #else
    $renderingParameters.selectedTransferFunctionChannel
    #endif
  }

  private var transferFunctionCanvas: some View {
    GeometryReader { geometry in
      CachedTransferFunctionPreview(
        transferFunction: renderingParameters.transferFunction,
        revision: renderingParameters.transferFunction.revision,
        refreshToken: previewRefreshToken
      )
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
  }

  @ViewBuilder
  private var transferFunctionToolbar: some View {
    if horizontalSizeClass == .compact {
      twoLineTransferFunctionToolbar
    } else {
      adaptiveTransferFunctionToolbar
    }
  }

  private var adaptiveTransferFunctionToolbar: some View {
    ViewThatFits(in: .horizontal) {
      oneLineTransferFunctionToolbar
      twoLineTransferFunctionToolbar
    }
  }

  private var oneLineTransferFunctionToolbar: some View {
    HStack(spacing: 12) {
      channelControls
      Spacer(minLength: 8)
      commandControls(menuMaxWidth: 220)
    }
  }

  private var twoLineTransferFunctionToolbar: some View {
    VStack(spacing: 8) {
      HStack(spacing: 12) {
        channelControls
        Spacer(minLength: 0)
      }

      HStack(spacing: 12) {
        commandControls(menuMaxWidth: nil)
      }
    }
  }

  private var channelControls: some View {
    HStack(spacing: 10) {
      channelButton(
        "R",
        color: .red,
        activeForeground: .white,
        help: "tf_editor_red_channel_help",
        isSelected: renderingParameters.transferEditing.red
      ) {
        renderingParameters.transferEditing.red.toggle()
        sharePlay.synchronize(kind: .stateOnly)
      }
      channelButton(
        "G",
        color: .green,
        activeForeground: .white,
        help: "tf_editor_green_channel_help",
        isSelected: renderingParameters.transferEditing.green
      ) {
        renderingParameters.transferEditing.green.toggle()
        sharePlay.synchronize(kind: .stateOnly)
      }
      channelButton(
        "B",
        color: .blue,
        activeForeground: .white,
        help: "tf_editor_blue_channel_help",
        isSelected: renderingParameters.transferEditing.blue
      ) {
        renderingParameters.transferEditing.blue.toggle()
        sharePlay.synchronize(kind: .stateOnly)
      }
      channelButton(
        "A",
        color: .white,
        activeForeground: .black,
        help: "tf_editor_alpha_channel_help",
        isSelected: renderingParameters.transferEditing.opacity
      ) {
        renderingParameters.transferEditing.opacity.toggle()
        sharePlay.synchronize(kind: .stateOnly)
      }
    }
  }

  private func commandControls(menuMaxWidth: CGFloat?) -> some View {
    HStack(spacing: 12) {
      Button {
        saveDescription = currentTransferFunctionDescription
        showingSaveDescriptionPrompt = true
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

      transferFunctionMenu(menuMaxWidth: menuMaxWidth)
        .frame(maxWidth: menuMaxWidth == nil ? .infinity : menuMaxWidth, alignment: .leading)

      Button {
        renderingParameters.objectWillChange.send()
        renderingParameters.transferFunction.reset()
        onMutation?()
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
      .help("Done")
      .accessibilityLabel("Done")
    }
    .screenControlButtons()
  }

  private func transferFunctionMenu(menuMaxWidth: CGFloat?) -> some View {
    Menu {
      if transferFunctionCatalog.isEmpty {
        Text("tf_catalog_empty")
      } else {
        ForEach(transferFunctionCatalog) { entry in
          Button {
            loadTransferFunction(from: entry)
          } label: {
            Label(entry.displayName, systemImage: currentTransferFunctionID == entry.id ? "checkmark" : "waveform")
          }
        }
      }
    } label: {
      Label(currentTransferFunctionMenuTitle, systemImage: currentTransferFunctionMenuIcon)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: menuMaxWidth ?? .infinity, alignment: .leading)
    }
    .help("tf_catalog_menu")
    .accessibilityLabel("tf_catalog_menu")
    .screenControlMenu()
  }

  private func channelButton(
    _ title: String,
    color: Color,
    activeForeground: Color,
    help: LocalizedStringKey,
    isSelected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      ZStack(alignment: .topTrailing) {
        RoundedRectangle(cornerRadius: 7)
          .fill(isSelected ? color : Color.secondary.opacity(0.16))
          .overlay {
            RoundedRectangle(cornerRadius: 7)
              .strokeBorder(
                isSelected ? Color.primary : Color.secondary.opacity(0.5),
                lineWidth: isSelected ? 2.5 : 1
              )
          }
          .shadow(
            color: isSelected ? color.opacity(0.45) : .clear,
            radius: 4,
            x: 0,
            y: 0
          )

        VStack {
          Spacer()
          HStack {
            Text(title)
              .font(.headline.weight(isSelected ? .black : .semibold))
              .monospaced()
              .foregroundStyle(isSelected ? activeForeground : Color.secondary)
            Spacer()
          }
        }
        .padding(.leading, 7)
        .padding(.bottom, 3)

        if isSelected {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 12, weight: .bold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(activeForeground, color)
            .background(Circle().fill(color))
            .offset(x: 4, y: -4)
        }
      }
      .frame(width: 34, height: 30)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .help(help)
    .accessibilityLabel(help)
  }

  private func paint(at point: CGPoint, in size: CGSize) {
    guard size.width > 0, size.height > 0 else { return }

    let current = normalizedPaintPoint(point, in: size)
    let channels = selectedChannels

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
    previewRefreshToken &+= 1
    onMutation?()
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
    guard let baseURL = appModel.transferFunctionFileURL() else { return nil }
    let urls = DatasetTransferFunctionStorage.fileURLs(baseURL: baseURL, componentCount: renderingParameters.componentCount)
    let channel = min(max(renderingParameters.selectedTransferFunctionChannel, 0), urls.count - 1)
    return urls[channel]
  }

  private var currentTransferFunctionID: String {
    renderingParameters.transferFunction.identifier
  }

  private var currentTransferFunctionCatalogEntry: TransferFunctionCatalogEntry? {
    transferFunctionCatalog.first { $0.id == currentTransferFunctionID }
  }

  private var currentTransferFunctionDescription: String {
    currentTransferFunctionCatalogEntry?.displayName ?? ""
  }

  private var currentTransferFunctionMenuTitle: String {
    currentTransferFunctionCatalogEntry?.displayName ?? String(localized: "tf_catalog_custom")
  }

  private var currentTransferFunctionMenuIcon: String {
    currentTransferFunctionCatalogEntry == nil ? "waveform" : "checkmark.circle"
  }

  private func refreshTransferFunctionCatalog() {
    transferFunctionCatalog = TransferFunctionCatalog.entries(
      additionalDirectoryURLs: catalogDirectoryURLs,
      datasetTransferFunctionURL: transferFunctionFileURL,
      logger: appModel.logger
    )
  }

  private func saveTransferFunction(description: String) {
    guard let fileURL = transferFunctionFileURL else { return }
    do {
      try renderingParameters.transferFunction.save(to: fileURL, description: description)
      let catalogURL = try TransferFunctionCatalog.store(
        transferFunction: renderingParameters.transferFunction,
        description: description,
        logger: appModel.logger
      )
      refreshTransferFunctionCatalog()
      appModel.logger.info(
        String(localized: "tf_editor_save_success") + " \(catalogURL.lastPathComponent)"
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
      try renderingParameters.loadTransferFunction(from: fileURL)
      onMutation?()
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

  private func loadTransferFunction(from entry: TransferFunctionCatalogEntry) {
    do {
      renderingParameters.objectWillChange.send()
      try renderingParameters.loadTransferFunction(from: entry.url)
      renderingParameters.renderMode = .transferFunction1D
      onMutation?()
      sharePlay.synchronize(kind: .full)
      appModel.logger.info(
        String(localized: "tf_editor_load_success") + " \(entry.url.lastPathComponent)"
      )
    } catch {
      appModel.logger.warning(
        String(localized: "tf_editor_load_failed") + " \(error.localizedDescription)"
      )
    }
  }
}

private struct CachedTransferFunctionPreview: View {
  private struct CacheKey: Hashable {
    let transferFunctionID: ObjectIdentifier
    let revision: UInt64
    let refreshToken: UInt64
    let pixelWidth: Int
    let pixelHeight: Int
  }

  let transferFunction: TransferFunction1D
  let revision: UInt64
  let refreshToken: UInt64

  @Environment(\.displayScale) private var displayScale
  @State private var cachedImage: CGImage?

  var body: some View {
    GeometryReader { geometry in
      let size = CGSize(
        width: max(1, geometry.size.width),
        height: max(1, geometry.size.height)
      )
      let key = CacheKey(
        transferFunctionID: ObjectIdentifier(transferFunction),
        revision: revision,
        refreshToken: refreshToken,
        pixelWidth: max(1, Int((size.width * displayScale).rounded())),
        pixelHeight: max(1, Int((size.height * displayScale).rounded()))
      )

      Group {
        if let cachedImage {
          Image(decorative: cachedImage, scale: displayScale, orientation: .up)
            .resizable()
            .interpolation(.high)
        } else {
          Color.black
        }
      }
      .transaction { transaction in
        transaction.animation = nil
        transaction.disablesAnimations = true
      }
      .task(id: key) {
        cachedImage = renderImage(size: size, scale: displayScale)
      }
    }
  }

  @MainActor
  private func renderImage(size: CGSize, scale: CGFloat) -> CGImage? {
    let maxSampleCount = max(2, Int((size.width * scale).rounded(.up)))
    let content = Canvas(opaque: true, colorMode: .nonLinear) { context, canvasSize in
      let rect = CGRect(origin: .zero, size: canvasSize)
      transferFunction.drawCheckerboard(in: context, rect: rect)
      transferFunction.drawRibbon(
        in: context,
        rect: rect.insetBy(dx: 0, dy: canvasSize.height * 0.38)
      )
      transferFunction.drawGrid(in: context, rect: rect)
      transferFunction.drawCurves(
        in: context,
        rect: rect,
        maxSampleCount: maxSampleCount
      )
    }
    .frame(width: size.width, height: size.height)
    .background(.black)

    let renderer = ImageRenderer(content: content)
    renderer.proposedSize = ProposedViewSize(size)
    renderer.scale = scale
    renderer.isOpaque = true
    return renderer.cgImage
  }
}
