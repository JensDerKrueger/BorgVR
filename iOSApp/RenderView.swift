import SwiftUI
import simd

struct RenderView: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var renderingParameters: RenderingParameters
  @EnvironmentObject var appSettings: AppSettings
  @EnvironmentObject private var serverController: BackgroundServerController
  @EnvironmentObject private var sharePlay: SharePlayCoordinator

  @State private var showTransferEditor = false
  @State private var showIsoEditor = false
  @State private var showLog = false
  @State private var showDatasetInfo = false
  @State private var showRenderControls = true
  @State private var previousDragTranslation = CGSize.zero
  @State private var previousMagnification: CGFloat = 1
  @State private var transferSmoothCenter: Float = 0.25
  @State private var transferSmoothWidth: Float = 0.3
  @State private var copiedWebGPUShareLink = false
  @State private var showMarkerEditor = false
  @State private var markerDragID: UUID?
  @State private var arcballStartOrientation: simd_quatf?
  @State private var showLeaveSharePlayConfirmation = false
  @StateObject private var renderSurface = MobileRenderSurface()

  private let clippingSensitivity: Float = 0.0012
  private let clippingPinchSensitivity: Float = 0.45
  private let transferSmoothCenterSensitivity: Float = 0.003
  private let transferSmoothSlopeSensitivity: Float = 0.003
  private let minimumTransferSmoothWidth: Float = 0.02
  private let maximumTransferSmoothWidth: Float = 1.0
  private let minimumModelScale: Float = 0.2
  private let maximumModelScale: Float = 20

  var body: some View {
    GeometryReader { proxy in
      let layout = AdaptiveLayout(
        size: proxy.size,
        safeAreaInsets: proxy.safeAreaInsets,
        horizontalSizeClass: horizontalSizeClass,
        verticalSizeClass: verticalSizeClass
      )

      renderContent(for: layout)
    }
    .sheet(isPresented: $showLog) {
      LoggerView(logger: appModel.logger)
    }
    .sheet(isPresented: $showDatasetInfo) {
      DatasetInfoView(dataset: appModel.activeDataset) {
        showDatasetInfo = false
      }
    }
    .sheet(isPresented: $showMarkerEditor) {
      MobileMarkerView()
        .environmentObject(appModel)
        .environmentObject(sharePlay)
    }
    .alert("Leave SharePlay?", isPresented: $showLeaveSharePlayConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Leave SharePlay", role: .destructive) {
        closeDataset(leavingSharePlay: true)
      }
    } message: {
      Text("Closing this dataset will leave the current SharePlay session.")
    }
  }

  @ViewBuilder
  private func renderContent(for layout: AdaptiveLayout) -> some View {
    ZStack(alignment: .top) {
      renderBackground
        .ignoresSafeArea()

      MobileMetalView(renderSurface: renderSurface)
        .ignoresSafeArea()
        .gesture(interactionGesture)
        .simultaneousGesture(zoomGesture)
        .simultaneousGesture(doubleTapInteractionGesture)
        .simultaneousGesture(markerTapGesture)

      switch layout.renderControlPlacement {
        case .overlayTop:
          topOverlayControls
      }

      if showIsoEditor && renderingParameters.renderMode == .isoValue {
        VStack {
          Spacer()

          IsovalueEditorView {
            showIsoEditor = false
          }
          .environmentObject(renderingParameters)
          .padding(.horizontal)
          .padding(.bottom)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }

      if showTransferEditor && renderingParameters.renderMode != .isoValue {
        VStack {
          Spacer()

          TransferFunctionEditorView(catalogDirectoryURLs: transferFunctionCatalogDirectoryURLs) {
            showTransferEditor = false
          }
          .environmentObject(renderingParameters)
          .frame(maxWidth: 720)
          .padding(.horizontal)
          .padding(.bottom)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
  }

  @ViewBuilder
  private var topOverlayControls: some View {
    if showRenderControls {
      VStack(spacing: 8) {
        HStack {
          Button {
            requestDatasetClose()
          } label: {
            Image(systemName: "xmark")
          }
          .accessibilityLabel(String(localized: "Close"))
          .buttonStyle(.borderedProminent)

          Spacer()

          Text(appModel.activeDataset?.description ?? "BorgVR Mobile")
            .font(.headline)
            .lineLimit(1)

          Spacer()

          ShareLink(
            item: BorgVRSharePlayActivity(),
            preview: SharePreview(String(localized: "BorgVR Mobile Live Collaboration"))
          ) {
            Image(systemName: "shareplay")
          }
          .simultaneousGesture(
            TapGesture().onEnded {
              sharePlay.markLocalActivityStarter()
            }
          )
          .accessibilityLabel(
            sharePlay.isInSession
              ? String(localized: "SharePlay active")
              : String(localized: "Start SharePlay")
          )
          .buttonStyle(.bordered)

          if canCopyWebGPUShareLink {
            Button {
              copyWebGPUShareLink()
            } label: {
              Image(systemName: copiedWebGPUShareLink ? "checkmark" : "link")
            }
            .accessibilityLabel("Copy WebGPU link")
            .help("Copy WebGPU link")
            .buttonStyle(.bordered)
          }

          Button {
            showDatasetInfo.toggle()
          } label: {
            Image(systemName: "info.circle")
          }
          .accessibilityLabel("dataset_info_button")
          .help("dataset_info_button_help")
          .buttonStyle(.bordered)

          Button {
            showLog.toggle()
          } label: {
            Image(systemName: "text.alignleft")
          }
          .accessibilityLabel("Log")
          .buttonStyle(.bordered)

          visibilityButton
        }

        Picker("Render Mode", selection: $renderingParameters.renderMode) {
          ForEach(RenderMode.allCases) { mode in
            Text(mode.description).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .onChange(of: renderingParameters.renderMode) {
          synchronizeState()
        }

        Picker("Interaction", selection: $appModel.interactionMode) {
          Text("Model").tag(AppModel.InteractionMode.model)
          Text("Clipping").tag(AppModel.InteractionMode.clipping)
          Text("Transfer").tag(AppModel.InteractionMode.transferEditing)
          Text("Marker").tag(AppModel.InteractionMode.marker)
        }
        .pickerStyle(.segmented)

        HStack {
          Toggle("Bricks", isOn: $renderingParameters.brickVis)
            .toggleStyle(.button)
            .onChange(of: renderingParameters.brickVis) {
              synchronizeState()
            }

          Button {
            renderingParameters.reset()
            synchronizeFullState()
            synchronizeTransform()
            sharePlay.flushSynchronization()
          } label: {
            Label("Reset", systemImage: "arrow.counterclockwise")
          }

          Button {
            if renderingParameters.renderMode == .isoValue {
              showTransferEditor = false
              showIsoEditor.toggle()
            } else {
              showIsoEditor = false
              showTransferEditor.toggle()
            }
          } label: {
            Label("Editor", systemImage: "slider.horizontal.3")
          }

          Button {
            showMarkerEditor = true
          } label: {
            Label("Markers", systemImage: "mappin.and.ellipse")
          }
        }
      }
      .padding(12)
      .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
      .padding()
    } else {
      HStack {
        Spacer()
        visibilityButton
      }
      .padding()
    }
  }

  @ViewBuilder
  private var renderBackground: some View {
    switch RenderBackgroundMode(rawValue: appSettings.renderBackgroundMode) ?? .system {
      case .system:
        Color(.systemBackground)
      case .solid:
        appSettings.renderBackgroundPrimaryColor
      case .gradient:
        LinearGradient(
          colors: [
            appSettings.renderBackgroundPrimaryColor,
            appSettings.renderBackgroundSecondaryColor
          ],
          startPoint: .top,
          endPoint: .bottom
        )
    }
  }

  private var transferFunctionCatalogDirectoryURLs: [URL] {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
  }

  private var canCopyWebGPUShareLink: Bool {
    guard let baseURL = serverController.shareableWebServerURL,
          let dataset = appModel.activeDataset,
          serverController.datasets.contains(where: {
            $0.id.caseInsensitiveCompare(dataset.uniqueId) == .orderedSame
          }) else {
      return false
    }

    return baseURL.scheme == "https"
  }

  private func shareableWebGPUURL() -> URL? {
    guard let baseURL = serverController.shareableWebServerURL,
          let dataset = appModel.activeDataset else {
      return nil
    }
    return WebGPUShareLink.datasetURL(
      baseURL: baseURL,
      datasetID: dataset.uniqueId,
      transferFunction: renderingParameters.transferFunction,
      renderMode: renderingParameters.renderMode,
      normalizedIsoValue: renderingParameters.normIsoValue
    )
  }

  private func copyWebGPUShareLink() {
    guard let url = shareableWebGPUURL() else { return }
    WebGPUShareLink.copyToPasteboard(url.absoluteString)
    copiedWebGPUShareLink = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
      copiedWebGPUShareLink = false
    }
  }

  private var visibilityButton: some View {
    Button {
      showRenderControls.toggle()
    } label: {
      Image(systemName: showRenderControls ? "eye.slash" : "eye")
    }
    .accessibilityLabel(
      showRenderControls
        ? String(localized: "Hide UI")
        : String(localized: "Show UI")
    )
    .buttonStyle(.bordered)
  }

  private var doubleTapInteractionGesture: some Gesture {
    TapGesture(count: 2)
      .onEnded {
        appModel.interactionMode = appModel.interactionMode == .clipping ? .model : .clipping
      }
  }

  private var interactionGesture: some Gesture {
    DragGesture(minimumDistance: 1, coordinateSpace: .global)
      .onChanged { value in
        let delta = CGSize(
          width: value.translation.width - previousDragTranslation.width,
          height: value.translation.height - previousDragTranslation.height
        )
        previousDragTranslation = value.translation

        switch appModel.interactionMode {
          case .model:
            guard let start = renderSurface.localPointAndSize(forGlobalPoint: value.startLocation),
                  let current = renderSurface.localPointAndSize(forGlobalPoint: value.location) else {
              return
            }
            rotateModel(
              from: start.point,
              to: current.point,
              in: current.size
            )
            synchronizeTransform()
          case .clipping:
            applyViewAlignedClipping(delta: delta)
            synchronizeState()
          case .transferEditing:
            applyTransferInteraction(delta: delta)
          case .marker:
            updateMarkerInteraction(atGlobalPoint: value.location)
        }
      }
      .onEnded { _ in
        previousDragTranslation = .zero
        arcballStartOrientation = nil
        markerDragID = nil
        sharePlay.flushSynchronization()
      }
  }

  private func updateMarkerInteraction(atGlobalPoint point: CGPoint) {
    guard let screenPosition = renderSurface.normalizedScreenPosition(forGlobalPoint: point) else {
      return
    }
    if markerDragID == nil {
      beginMarkerInteraction(at: screenPosition)
    }

    guard let markerDragID,
          let index = appModel.volumeMarkers.firstIndex(where: { $0.id == markerDragID }),
          let position = appModel.markerPositionHandler?(
            screenPosition,
            appModel.volumeMarkers[index].position
          ) else { return }
    appModel.volumeMarkers[index].position = position
    sharePlay.synchronizeMarkers()
  }

  private func beginMarkerInteraction(at screenPosition: SIMD2<Float>) {
    if let markerID = appModel.markerHitTestHandler?(screenPosition) {
      appModel.selectedVolumeMarkerID = markerID
      markerDragID = markerID
    } else if let position = appModel.markerPositionHandler?(screenPosition, nil),
              let directionOrigin = appModel.markerDirectionOriginHandler?(screenPosition) {
      let marker = VolumeMarker(
        id: UUID(),
        name: appModel.nextVolumeMarkerName(),
        position: position,
        radius: appModel.defaultVolumeMarkerRadius,
        color: appModel.defaultVolumeMarkerColor,
        directionOrigin: directionOrigin
      )
      appModel.volumeMarkers.append(marker)
      appModel.selectedVolumeMarkerID = marker.id
      markerDragID = marker.id
      sharePlay.synchronizeMarkers(immediately: true)
    }
  }

  private var markerTapGesture: some Gesture {
    SpatialTapGesture(count: 1, coordinateSpace: .global)
      .onEnded { value in
        guard appModel.interactionMode == .marker,
              let screenPosition = renderSurface.normalizedScreenPosition(
                forGlobalPoint: value.location
              ) else { return }
        beginMarkerInteraction(at: screenPosition)
        markerDragID = nil
        sharePlay.flushSynchronization()
      }
  }

  private func rotateModel(from start: CGPoint, to current: CGPoint, in viewSize: CGSize) {
    guard viewSize.width > 0, viewSize.height > 0 else { return }
    let startOrientation = arcballStartOrientation ?? renderingParameters.orientation
    if arcballStartOrientation == nil {
      arcballStartOrientation = startOrientation
    }

    let startVector = arcballVector(at: start, in: viewSize)
    let currentVector = arcballVector(at: current, in: viewSize)
    let rotation = quaternionRotating(from: startVector, to: currentVector)
    renderingParameters.orientation = simd_normalize(rotation * startOrientation)
  }

  private func arcballVector(at location: CGPoint, in viewSize: CGSize) -> SIMD3<Float> {
    let radius = Float(max(1, min(viewSize.width, viewSize.height) * 0.5))
    var vector = SIMD3<Float>(
      (Float(location.x) - Float(viewSize.width) * 0.5) / radius,
      (Float(viewSize.height) * 0.5 - Float(location.y)) / radius,
      0
    )
    let distanceSquared = vector.x * vector.x + vector.y * vector.y
    if distanceSquared <= 1 {
      vector.z = sqrt(1 - distanceSquared)
      return vector
    }
    return simd_normalize(vector)
  }

  private func quaternionRotating(
    from start: SIMD3<Float>,
    to end: SIMD3<Float>
  ) -> simd_quatf {
    let cosine = min(1, max(-1, simd_dot(start, end)))
    if cosine < -0.9999 {
      let reference = abs(start.x) < 0.9
        ? SIMD3<Float>(1, 0, 0)
        : SIMD3<Float>(0, 1, 0)
      return simd_quatf(angle: .pi, axis: simd_normalize(simd_cross(start, reference)))
    }

    let axis = simd_cross(start, end)
    return simd_normalize(
      simd_quatf(ix: axis.x, iy: axis.y, iz: axis.z, r: 1 + cosine)
    )
  }

  private func applyTransferInteraction(delta: CGSize) {
    if renderingParameters.renderMode == .isoValue {
      let transferDelta = Float(delta.width) * 0.0006
      renderingParameters.normIsoValue = min(1, max(0, renderingParameters.normIsoValue + transferDelta))
      synchronizeState()
      return
    }

    renderingParameters.objectWillChange.send()
    transferSmoothCenter = clamp(transferSmoothCenter + Float(delta.width) * transferSmoothCenterSensitivity)
    transferSmoothWidth = clamp(
      transferSmoothWidth - Float(delta.height) * transferSmoothSlopeSensitivity,
      minimumTransferSmoothWidth,
      maximumTransferSmoothWidth
    )
    renderingParameters.transferFunction.smoothStep(
      start: transferSmoothCenter - transferSmoothWidth * 0.5,
      shift: transferSmoothWidth,
      channels: [0, 1, 2, 3]
    )
    sharePlay.synchronize(kind: .full)
  }

  private func clamp(_ value: Float, _ lowerBound: Float = 0, _ upperBound: Float = 1) -> Float {
    min(upperBound, max(lowerBound, value))
  }

  private func applyViewAlignedClipping(delta: CGSize) {
    let axes = rotatedVolumeAxes()
    let horizontalAxis = bestProjectedAxis(axes, component: 0)
    let verticalAxis = bestProjectedAxis(axes, component: 1, excluding: horizontalAxis)

    if abs(delta.width) > 0 {
      let axisDirection = axes[horizontalAxis].x >= 0 ? Float(1) : Float(-1)
      updateClipping(axis: horizontalAxis, delta: Float(delta.width) * axisDirection * clippingSensitivity)
    }

    if abs(delta.height) > 0 {
      let axisDirection = axes[verticalAxis].y >= 0 ? Float(1) : Float(-1)
      updateClipping(axis: verticalAxis, delta: -Float(delta.height) * axisDirection * clippingSensitivity)
    }
  }

  private func applyDepthAlignedClipping(magnificationDelta: CGFloat) {
    let axes = rotatedVolumeAxes()
    let horizontalAxis = bestProjectedAxis(axes, component: 0)
    let verticalAxis = bestProjectedAxis(axes, component: 1, excluding: horizontalAxis)
    let depthAxis = axes.indices.first { $0 != horizontalAxis && $0 != verticalAxis } ?? bestProjectedAxis(axes, component: 2)
    let axisDirection = axes[depthAxis].z >= 0 ? Float(1) : Float(-1)
    let delta = -Float(log(Double(magnificationDelta))) * axisDirection * clippingPinchSensitivity
    updateClipping(axis: depthAxis, delta: delta)
  }

  private func rotatedVolumeAxes() -> [SIMD3<Float>] {
    let rotation = simd_float4x4(renderingParameters.orientation)
    let localAxes = [
      SIMD4<Float>(1, 0, 0, 0),
      SIMD4<Float>(0, 1, 0, 0),
      SIMD4<Float>(0, 0, 1, 0)
    ]

    return localAxes.map { axis in
      let projected = rotation * axis
      return SIMD3<Float>(projected.x, projected.y, projected.z)
    }
  }

  private func bestProjectedAxis(_ axes: [SIMD3<Float>], component: Int, excluding excludedAxis: Int? = nil) -> Int {
    var bestAxis = 0
    var bestAlignment: Float = -1

    for axis in axes.indices where axis != excludedAxis {
      let alignment = abs(axes[axis][component])
      if alignment > bestAlignment {
        bestAlignment = alignment
        bestAxis = axis
      }
    }

    return bestAxis
  }

  private func updateClipping(axis: Int, delta: Float) {
    renderingParameters.clippingTranslation[axis] = min(0.98, max(-0.98, renderingParameters.clippingTranslation[axis] + delta))
    let translation = renderingParameters.clippingTranslation[axis]

    if translation >= 0 {
      renderingParameters.clipMin[axis] = translation
      renderingParameters.clipMax[axis] = 1
    } else {
      renderingParameters.clipMin[axis] = 0
      renderingParameters.clipMax[axis] = 1 + translation
    }
  }

  private var zoomGesture: some Gesture {
    MagnifyGesture()
      .onChanged { value in
        let delta = value.magnification / previousMagnification
        previousMagnification = value.magnification
        if appModel.interactionMode == .clipping {
          applyDepthAlignedClipping(magnificationDelta: delta)
          synchronizeState()
        } else if appModel.interactionMode == .marker {
          scaleSelectedMarker(by: Float(delta))
        } else {
          renderingParameters.scale = min(maximumModelScale, max(minimumModelScale, renderingParameters.scale * Float(delta)))
          synchronizeTransform()
        }
      }
      .onEnded { _ in
        previousMagnification = 1
        sharePlay.flushSynchronization()
      }
  }

  private func scaleSelectedMarker(by factor: Float) {
    guard let markerID = appModel.selectedVolumeMarkerID,
          let index = appModel.volumeMarkers.firstIndex(where: { $0.id == markerID }) else { return }
    let markerKind = appModel.volumeMarkers[index].kind
    let radius = VolumeMarkerRadius.clamp(
      appModel.volumeMarkers[index].radius * factor,
      for: markerKind
    )
    appModel.volumeMarkers[index].radius = radius
    if markerKind == .sphere {
      appModel.defaultVolumeMarkerRadius = radius
    }
    sharePlay.synchronizeMarkers()
  }

  private func requestDatasetClose() {
    if sharePlay.isInSession, !appModel.groupSessionHost {
      showLeaveSharePlayConfirmation = true
    } else {
      closeDataset(leavingSharePlay: false)
    }
  }

  private func closeDataset(leavingSharePlay: Bool) {
    if appSettings.autoloadTF,
       let fileURL = appModel.transferFunctionFileURL() {
      try? renderingParameters.transferFunction.save(to: fileURL)
    }
    if leavingSharePlay {
      sharePlay.leaveGroupActivity()
    } else {
      sharePlay.closeSharedDataset()
    }
    appModel.volumeMarkers.removeAll()
    appModel.selectedVolumeMarkerID = nil
    appModel.currentState = .selectData
  }

  private func synchronizeTransform() {
    sharePlay.synchronize(kind: .transformOnly)
  }

  private func synchronizeState() {
    sharePlay.synchronize(kind: .stateOnly)
  }

  private func synchronizeFullState() {
    sharePlay.synchronize(kind: .full)
  }
}
