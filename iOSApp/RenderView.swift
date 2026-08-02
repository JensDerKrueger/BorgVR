import SwiftUI
import simd

struct RenderView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var renderingParameters: RenderingParameters
  @EnvironmentObject var appSettings: AppSettings
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

  private let modelRotationSensitivity: Float = 0.006
  private let clippingSensitivity: Float = 0.0012
  private let clippingPinchSensitivity: Float = 0.45
  private let transferSmoothCenterSensitivity: Float = 0.003
  private let transferSmoothSlopeSensitivity: Float = 0.003
  private let minimumTransferSmoothWidth: Float = 0.02
  private let maximumTransferSmoothWidth: Float = 1.0
  private let minimumModelScale: Float = 0.2
  private let maximumModelScale: Float = 20

  var body: some View {
    ZStack(alignment: .top) {
      renderBackground
        .ignoresSafeArea()

      MobileMetalView()
        .ignoresSafeArea()
        .gesture(rotationGesture)
        .simultaneousGesture(zoomGesture)
        .simultaneousGesture(doubleTapInteractionGesture)

      if showRenderControls {
        VStack(spacing: 8) {
          HStack {
            Button {
              closeDataset()
            } label: {
              Image(systemName: "xmark")
            }
            .accessibilityLabel(String(localized: "Schließen"))
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
                ? String(localized: "SharePlay aktiv")
                : String(localized: "SharePlay starten")
            )
            .buttonStyle(.bordered)

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
            Text("Modell").tag(AppModel.InteractionMode.model)
            Text("Clipping").tag(AppModel.InteractionMode.clipping)
            Text("Transfer").tag(AppModel.InteractionMode.transferEditing)
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

          TransferFunctionEditorView {
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
    .sheet(isPresented: $showLog) {
      LoggerView(logger: appModel.logger)
    }
    .sheet(isPresented: $showDatasetInfo) {
      DatasetInfoView(dataset: appModel.activeDataset) {
        showDatasetInfo = false
      }
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

  private var visibilityButton: some View {
    Button {
      showRenderControls.toggle()
    } label: {
      Image(systemName: showRenderControls ? "eye.slash" : "eye")
    }
    .accessibilityLabel(
      showRenderControls
        ? String(localized: "UI ausblenden")
        : String(localized: "UI einblenden")
    )
    .buttonStyle(.bordered)
  }

  private var doubleTapInteractionGesture: some Gesture {
    TapGesture(count: 2)
      .onEnded {
        appModel.interactionMode = appModel.interactionMode == .clipping ? .model : .clipping
      }
  }

  private var rotationGesture: some Gesture {
    DragGesture(minimumDistance: 1)
      .onChanged { value in
        let delta = CGSize(
          width: value.translation.width - previousDragTranslation.width,
          height: value.translation.height - previousDragTranslation.height
        )
        previousDragTranslation = value.translation

        switch appModel.interactionMode {
          case .model:
            rotateModel(by: delta)
            synchronizeTransform()
          case .clipping:
            applyViewAlignedClipping(delta: delta)
            synchronizeState()
          case .transferEditing:
            applyTransferInteraction(delta: delta)
        }
      }
      .onEnded { _ in
        previousDragTranslation = .zero
        sharePlay.flushSynchronization()
      }
  }

  private func rotateModel(by delta: CGSize) {
    let xAngle = Float(delta.height) * modelRotationSensitivity
    let yAngle = Float(delta.width) * modelRotationSensitivity
    guard xAngle != 0 || yAngle != 0 else { return }

    let xRotation = simd_quatf(angle: xAngle, axis: SIMD3<Float>(1, 0, 0))
    let yRotation = simd_quatf(angle: yAngle, axis: SIMD3<Float>(0, 1, 0))
    renderingParameters.orientation = simd_normalize(yRotation * xRotation * renderingParameters.orientation)
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

  private func closeDataset() {
    if appModel.activeDataset?.source == .local,
       let identifier = appModel.activeDataset?.identifier,
       appSettings.autoloadTF {
      let fileURL = URL(fileURLWithPath: identifier).deletingPathExtension().appendingPathExtension("tf1d")
      try? renderingParameters.transferFunction.save(to: fileURL)
    }
    sharePlay.closeSharedDataset()
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
