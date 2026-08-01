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
  @State private var showRenderControls = true
  @State private var selectedInteractionMode: AppModel.InteractionMode = .model
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

      MacMetalView(
        onDragUpdate: applyInteractionDrag(update:),
        onDragEnded: finishInteractionGesture,
        onMagnificationDelta: applyMagnificationDelta(_:),
        onMagnificationEnded: finishInteractionGesture,
        onDoubleTap: toggleInteractionMode
      )
        .ignoresSafeArea()

      if showRenderControls {
        VStack(spacing: 8) {
          HStack {
            Button {
              closeDataset()
            } label: {
              Image(systemName: "xmark")
            }
            .accessibilityLabel("Schließen")
            .buttonStyle(.borderedProminent)

            Spacer()

            Text(appModel.activeDataset?.description ?? "BorgVR macOS")
              .font(.headline)
              .lineLimit(1)

            Spacer()

            ShareLink(
              item: BorgVRSharePlayActivity(),
              preview: SharePreview(String(localized: "BorgVR macOS Live Collaboration"))
            ) {
              Image(systemName: "shareplay")
            }
            .simultaneousGesture(
              TapGesture().onEnded {
                sharePlay.markLocalActivityStarter()
              }
            )
            .accessibilityLabel(sharePlay.isInSession ? "SharePlay aktiv" : "SharePlay starten")
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

          Picker("Interaction", selection: $selectedInteractionMode) {
            Text("Modell").tag(AppModel.InteractionMode.model)
            Text("Clipping").tag(AppModel.InteractionMode.clipping)
            Text("Transfer").tag(AppModel.InteractionMode.transferEditing)
          }
          .pickerStyle(.segmented)
          .onAppear {
            selectedInteractionMode = appModel.interactionMode
          }
          .onChange(of: selectedInteractionMode) { _, newValue in
            applyInteractionModeSelection(newValue)
          }
          .onChange(of: appModel.interactionMode) { _, newValue in
            if selectedInteractionMode != newValue {
              selectedInteractionMode = newValue
            }
          }

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
  }

  @ViewBuilder
  private var renderBackground: some View {
    switch RenderBackgroundMode(rawValue: appSettings.renderBackgroundMode) ?? .system {
      case .system:
        Color(nsColor: .windowBackgroundColor)
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
    .accessibilityLabel(showRenderControls ? "UI ausblenden" : "UI einblenden")
    .buttonStyle(.bordered)
  }

  private func toggleInteractionMode() {
    let newMode: AppModel.InteractionMode = appModel.interactionMode == .clipping ? .model : .clipping
    selectedInteractionMode = newMode
    applyInteractionModeSelection(newMode)
  }

  private func applyInteractionModeSelection(_ mode: AppModel.InteractionMode) {
    DispatchQueue.main.async {
      guard appModel.interactionMode != mode else { return }
      appModel.interactionMode = mode
    }
  }

  private func applyInteractionDrag(update: RenderDragUpdate) {
    switch appModel.interactionMode {
      case .model:
        rotateModel(by: update.delta)
        synchronizeTransform()
      case .clipping:
        applyViewAlignedClipping(delta: update.delta)
        synchronizeState()
      case .transferEditing:
        applyTransferInteraction(update: update)
    }
  }

  private func applyMagnificationDelta(_ delta: CGFloat) {
    guard delta > 0 else { return }
    if appModel.interactionMode == .clipping {
      applyDepthAlignedClipping(magnificationDelta: delta)
      synchronizeState()
    } else {
      renderingParameters.scale = min(maximumModelScale, max(minimumModelScale, renderingParameters.scale * Float(delta)))
      synchronizeTransform()
    }
  }

  private func finishInteractionGesture() {
    sharePlay.flushSynchronization()
  }

  private func applyTransferInteraction(update: RenderDragUpdate) {
    if renderingParameters.renderMode == .isoValue {
      let transferDelta = Float(update.delta.width) * 0.0006
      renderingParameters.normIsoValue = min(1, max(0, renderingParameters.normIsoValue + transferDelta))
      synchronizeState()
      return
    }

    renderingParameters.objectWillChange.send()
    let parameters = transferSmoothParameters(for: update)
    transferSmoothCenter = parameters.center
    transferSmoothWidth = parameters.width
    renderingParameters.transferFunction.smoothStep(
      start: parameters.center - parameters.width * 0.5,
      shift: parameters.width,
      channels: [0, 1, 2, 3]
    )
    sharePlay.synchronize(kind: .full)
  }

  private func transferSmoothParameters(for update: RenderDragUpdate) -> (center: Float, width: Float) {
    guard update.viewSize.width > 0, update.viewSize.height > 0 else {
      return (transferSmoothCenter, transferSmoothWidth)
    }

    if update.isDirectPointer {
      let center = clamp(Float(update.location.x / update.viewSize.width))
      let steepness = clamp(Float(update.location.y / update.viewSize.height))
      let width = maximumTransferSmoothWidth - steepness * (maximumTransferSmoothWidth - minimumTransferSmoothWidth)
      return (center, width)
    }

    return (
      clamp(transferSmoothCenter + Float(update.delta.width) * transferSmoothCenterSensitivity),
      clamp(
        transferSmoothWidth - Float(update.delta.height) * transferSmoothSlopeSensitivity,
        minimumTransferSmoothWidth,
        maximumTransferSmoothWidth
      )
    )
  }

  private func clamp(_ value: Float, _ lowerBound: Float = 0, _ upperBound: Float = 1) -> Float {
    min(upperBound, max(lowerBound, value))
  }

  private func rotateModel(by delta: CGSize) {
    let xAngle = Float(delta.height) * modelRotationSensitivity
    let yAngle = Float(delta.width) * modelRotationSensitivity
    guard xAngle != 0 || yAngle != 0 else { return }

    let xRotation = simd_quatf(angle: xAngle, axis: SIMD3<Float>(1, 0, 0))
    let yRotation = simd_quatf(angle: yAngle, axis: SIMD3<Float>(0, 1, 0))
    renderingParameters.orientation = simd_normalize(yRotation * xRotation * renderingParameters.orientation)
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
