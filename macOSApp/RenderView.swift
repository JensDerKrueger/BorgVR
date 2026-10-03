import SwiftUI
import simd

struct RenderView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var renderingParameters: RenderingParameters
  @EnvironmentObject var appSettings: AppSettings
  @EnvironmentObject private var storedAppModel: StoredAppModel
  @EnvironmentObject private var sharePlay: SharePlayCoordinator
  @EnvironmentObject private var docking: DockingController
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow

  @State private var transferSmoothCenter: Float = 0.25
  @State private var transferSmoothWidth: Float = 0.3
  @State private var restoredDetachedPanelWindows: Set<DockablePanelID> = []
  @State private var markerDragID: UUID?
  @State private var measurementDragMeasurementID: UUID?
  @State private var measurementDragPointID: UUID?
  @State private var arcballStartLocation: CGPoint?
  @State private var arcballStartOrientation: simd_quatf?

  private let modelRotationSensitivity: Float = 0.006
  private let clippingSensitivity: Float = 0.0012
  private let clippingPinchSensitivity: Float = 0.45
  private let transferSmoothCenterSensitivity: Float = 0.003
  private let transferSmoothSlopeSensitivity: Float = 0.003
  private let minimumTransferSmoothWidth: Float = 0.02
  private let maximumTransferSmoothWidth: Float = 1.0
  private let minimumModelScale: Float = 0.2
  private let maximumModelScale: Float = 20
  private let dockedLightingPanelWidth: CGFloat = 340
  private let dockedMarkerPanelWidth: CGFloat = 380
  private let markerDepthScrollSensitivity: Float = 0.003

  var body: some View {
    ZStack(alignment: .top) {
      renderBackground
        .ignoresSafeArea()

      MacMetalView(
        onDragUpdate: applyInteractionDrag(update:),
        onDragEnded: finishInteractionGesture,
        onPointerDown: beginInteraction(update:),
        onMagnificationDelta: applyMagnificationDelta(_:),
        onMagnificationEnded: finishInteractionGesture,
        onDoubleTap: toggleInteractionMode
      )
        .ignoresSafeArea()

      if docking.isDockedVisible(.renderControls) {
        RenderControlsPanel(isDetachedWindow: false)
          .padding()
      } else if !docking.isDetached(.renderControls) {
        HStack {
          Spacer()
          visibilityButton
        }
        .padding()
      }

      if docking.isDockedVisible(.isoEditor) && renderingParameters.renderMode == .isoValue {
        VStack {
          Spacer()

          DockableEditorPanel(panel: .isoEditor, maxWidth: 520) {
            IsovalueEditorView(usesPanelBackground: false) {
              docking.hide(.isoEditor)
            }
            .environmentObject(renderingParameters)
          }
          .padding(.leading, dockedEditorLeadingPadding)
          .padding(.trailing, dockedEditorTrailingPadding)
          .padding(.bottom)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }

      if docking.isDockedVisible(.transferFunctionEditor) && renderingParameters.renderMode != .isoValue {
        VStack {
          Spacer()

          DockableEditorPanel(panel: .transferFunctionEditor, maxWidth: 720) {
            TransferFunctionEditorView(
              usesPanelBackground: false,
              catalogDirectoryURLs: transferFunctionCatalogDirectoryURLs
            ) {
              docking.hide(.transferFunctionEditor)
            }
            .environmentObject(renderingParameters)
          }
          .padding(.leading, dockedEditorLeadingPadding)
          .padding(.trailing, dockedEditorTrailingPadding)
          .padding(.bottom)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }

      measurementLabels

      if docking.isDockedVisible(.markerEditor) ||
         docking.isDockedVisible(.measurementEditor) ||
         docking.isDockedVisible(.lightingEditor) {
        HStack(alignment: .top, spacing: 16) {
          if docking.isDockedVisible(.lightingEditor) {
            VStack {
              Spacer(minLength: 0)

              DockableEditorPanel(panel: .lightingEditor) {
                LightingEditorView(
                  lightDirection: $renderingParameters.lightDirection,
                  ambientLightColor: $renderingParameters.ambientLightColor,
                  diffuseLightColor: $renderingParameters.diffuseLightColor,
                  specularLightColor: $renderingParameters.specularLightColor,
                  usesPanelBackground: false,
                  showsTitle: false,
                  onChange: { sharePlay.synchronize(kind: .stateOnly) },
                  onCommit: sharePlay.flushSynchronization,
                  onClose: { docking.hide(.lightingEditor) }
                )
              }
            }
            .frame(width: dockedLightingPanelWidth)
            .frame(maxHeight: .infinity)
            .transition(.move(edge: .leading).combined(with: .opacity))
          }

          Spacer(minLength: 0)

          HStack(spacing: 16) {
            if docking.isDockedVisible(.measurementEditor) {
              DockableEditorPanel(panel: .measurementEditor) {
                MacMeasurementView()
              }
              .frame(width: dockedMarkerPanelWidth)
              .frame(maxHeight: .infinity)
              .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if docking.isDockedVisible(.markerEditor) {
              DockableEditorPanel(panel: .markerEditor) {
                MacMarkerView()
              }
              .frame(width: dockedMarkerPanelWidth)
              .frame(maxHeight: .infinity)
              .transition(.move(edge: .trailing).combined(with: .opacity))
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, docking.isDockedVisible(.renderControls) ? 190 : 16)
        .padding(.horizontal)
        .padding(.bottom)
      }
    }
    .onAppear {
      docking.restoreForDatasetOpen()
      updateDetachedPanelWindows()
    }
    .onChange(of: renderingParameters.renderMode) {
      updateDetachedPanelWindows()
    }
    .onChange(of: appSettings.showBrickVisualization) { _, isVisible in
      guard !isVisible, renderingParameters.brickVis else { return }
      renderingParameters.brickVis = false
      sharePlay.synchronize(kind: .stateOnly)
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
      docking.show(.renderControls)
    } label: {
      Image(systemName: "eye")
    }
    .accessibilityLabel("Show UI")
    .help("Show UI")
    .buttonStyle(.bordered)
  }

  private var transferFunctionCatalogDirectoryURLs: [URL] {
    [storedAppModel.resolvedDataDirectoryURL()]
  }

  private var dockedEditorLeadingPadding: CGFloat {
    docking.isDockedVisible(.lightingEditor)
      ? dockedLightingPanelWidth + 32
      : 16
  }

  private var dockedEditorTrailingPadding: CGFloat {
    CGFloat(
      [DockablePanelID.markerEditor, .measurementEditor]
        .filter { docking.isDockedVisible($0) }.count
    ) * (dockedMarkerPanelWidth + 16) + 16
  }

  private func updateDetachedPanelWindows() {
    temporarilyCloseIncompatibleDetachedPanelWindows()
    restoreDetachedPanelWindows()
  }

  private func temporarilyCloseIncompatibleDetachedPanelWindows() {
    for panel in docking.detachedPanelsToTemporarilyClose(incompatibleWith: renderingParameters.renderMode) {
      docking.markDetachedWindowTemporarilyClosed(panel)
      dismissWindow(id: panel.windowID)
      restoredDetachedPanelWindows.remove(panel)
    }
  }

  private func restoreDetachedPanelWindows() {
    for panel in docking.detachedPanelsToRestore(compatibleWith: renderingParameters.renderMode) {
      guard !restoredDetachedPanelWindows.contains(panel) else { continue }
      openWindow(id: panel.windowID)
      restoredDetachedPanelWindows.insert(panel)
    }
  }

  private func toggleInteractionMode() {
    if appModel.interactionMode == .measurement {
      if appModel.removeSelectedVolumeMeasurementPoint() {
        sharePlay.synchronizeMeasurements()
      }
      return
    }
    let newMode: AppModel.InteractionMode = appModel.interactionMode == .clipping ? .model : .clipping
    applyInteractionModeSelection(newMode)
  }

  private func applyInteractionModeSelection(_ mode: AppModel.InteractionMode) {
    DispatchQueue.main.async {
      guard appModel.interactionMode != mode else { return }
      if mode != .measurement {
        appModel.clearVolumeMeasurementSelection()
      }
      appModel.interactionMode = mode
    }
  }

  private func applyInteractionDrag(update: RenderDragUpdate) {
    switch appModel.interactionMode {
      case .model:
        if update.isDirectPointer {
          rotateModel(to: update.location, in: update.viewSize)
        } else {
          rotateModelIncrementally(by: update.delta)
        }
        synchronizeTransform()
      case .clipping:
        applyViewAlignedClipping(delta: update.delta)
        synchronizeState()
      case .transferEditing:
        applyTransferInteraction(update: update)
      case .marker:
        if update.isDirectPointer {
          updateMarkerInteraction(update: update)
        } else {
          moveSelectedMarkerInDepth(by: update.delta.height)
        }
      case .measurement:
        if update.isDirectPointer {
          updateMeasurementInteraction(update: update)
        } else {
          moveSelectedMeasurementPointInDepth(by: update.delta.height)
        }
    }
  }

  private func applyMagnificationDelta(_ delta: CGFloat) {
    guard delta > 0 else { return }
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

  private func finishInteractionGesture() {
    arcballStartLocation = nil
    arcballStartOrientation = nil
    markerDragID = nil
    measurementDragMeasurementID = nil
    measurementDragPointID = nil
    sharePlay.flushSynchronization()
  }

  private func beginInteraction(update: RenderDragUpdate) {
    switch appModel.interactionMode {
      case .model:
        arcballStartLocation = update.location
        arcballStartOrientation = renderingParameters.orientation
      case .marker:
        beginMarkerInteraction(update: update)
      case .measurement:
        beginMeasurementInteraction(update: update)
      case .clipping, .transferEditing:
        break
    }
  }

  private func beginMarkerInteraction(update: RenderDragUpdate) {
    guard appModel.interactionMode == .marker,
          update.viewSize.width > 0,
          update.viewSize.height > 0 else { return }
    let screenPosition = SIMD2<Float>(
      Float(update.location.x / update.viewSize.width),
      Float(update.location.y / update.viewSize.height)
    )
    if let markerID = appModel.markerHitTestHandler?(screenPosition) {
      appModel.selectedVolumeMarkerID = markerID
      markerDragID = markerID
      return
    }
    guard let position = appModel.markerPositionHandler?(screenPosition, nil),
          let directionOrigin = appModel.markerDirectionOriginHandler?(screenPosition) else { return }
    let marker = VolumeMarker(
      id: UUID(),
      name: appModel.nextVolumeMarkerName(),
      position: position,
      radius: appModel.defaultVolumeMarkerRadius,
      color: appModel.defaultVolumeMarkerColor,
      directionOrigin: directionOrigin,
      showsDirection: appModel.defaultVolumeMarkerShowsDirection
    )
    appModel.volumeMarkers.append(marker)
    appModel.selectedVolumeMarkerID = marker.id
    markerDragID = marker.id
    sharePlay.synchronizeMarkers()
  }

  private func updateMarkerInteraction(update: RenderDragUpdate) {
    if markerDragID == nil {
      beginMarkerInteraction(update: update)
    }
    guard let markerDragID,
          let index = appModel.volumeMarkers.firstIndex(where: { $0.id == markerDragID }),
          update.viewSize.width > 0,
          update.viewSize.height > 0 else { return }
    let screenPosition = SIMD2<Float>(
      Float(update.location.x / update.viewSize.width),
      Float(update.location.y / update.viewSize.height)
    )
    guard let position = appModel.markerPositionHandler?(
      screenPosition,
      appModel.volumeMarkers[index].position
    ) else { return }
    let offset = position - appModel.volumeMarkers[index].position
    for selectedIndex in appModel.volumeMarkers.indices
      where appModel.selectedVolumeMarkerIDs.contains(appModel.volumeMarkers[selectedIndex].id) {
      appModel.volumeMarkers[selectedIndex].translate(by: offset)
    }
    sharePlay.synchronizeMarkers()
  }

  private func scaleSelectedMarker(by factor: Float) {
    guard let markerID = appModel.selectedVolumeMarkerID,
          let index = appModel.volumeMarkers.firstIndex(where: { $0.id == markerID }) else { return }
    for selectedIndex in appModel.volumeMarkers.indices
      where appModel.selectedVolumeMarkerIDs.contains(appModel.volumeMarkers[selectedIndex].id) {
      appModel.volumeMarkers[selectedIndex].scaleRadii(by: factor)
    }
    if appModel.volumeMarkers[index].kind == .sphere {
      appModel.defaultVolumeMarkerRadius = appModel.volumeMarkers[index].radius
    }
    sharePlay.synchronizeMarkers()
  }

  private func moveSelectedMarkerInDepth(by scrollDelta: CGFloat) {
    guard scrollDelta != 0,
          let markerID = appModel.selectedVolumeMarkerID,
          let index = appModel.volumeMarkers.firstIndex(where: { $0.id == markerID }),
          let position = appModel.markerDepthAdjustmentHandler?(
            appModel.volumeMarkers[index].position,
            Float(scrollDelta) * markerDepthScrollSensitivity
          ) else { return }
    let offset = position - appModel.volumeMarkers[index].position
    for selectedIndex in appModel.volumeMarkers.indices
      where appModel.selectedVolumeMarkerIDs.contains(appModel.volumeMarkers[selectedIndex].id) {
      appModel.volumeMarkers[selectedIndex].translate(by: offset)
    }
    sharePlay.synchronizeMarkers()
  }

  private func normalizedPosition(for update: RenderDragUpdate) -> SIMD2<Float>? {
    guard update.viewSize.width > 0, update.viewSize.height > 0 else { return nil }
    return SIMD2<Float>(
      Float(update.location.x / update.viewSize.width),
      Float(update.location.y / update.viewSize.height)
    )
  }

  private func beginMeasurementInteraction(update: RenderDragUpdate) {
    guard let screenPosition = normalizedPosition(for: update) else { return }
    if let hit = appModel.measurementHitTestHandler?(screenPosition) {
      appModel.selectedVolumeMeasurementID = hit.measurementID
      appModel.selectedVolumeMeasurementPointID = hit.pointID
      measurementDragMeasurementID = hit.measurementID
      measurementDragPointID = hit.pointID
      if let measurement = appModel.volumeMeasurements.first(where: { $0.id == hit.measurementID }) {
        appModel.measurementKind = measurement.kind
      }
      return
    }
    guard let position = appModel.markerPositionHandler?(screenPosition, nil),
          let extent = appModel.activeDatasetMetadata?.physicalExtentMeters else { return }
    var measurementID = appModel.selectedVolumeMeasurementID
    if measurementID.flatMap({ id in
      appModel.volumeMeasurements.first(where: { $0.id == id })?.kind
    }) != appModel.measurementKind {
      measurementID = appModel.volumeMeasurements.last(where: {
        $0.kind == appModel.measurementKind
      })?.id
    }
    if measurementID == nil { measurementID = appModel.createVolumeMeasurement() }
    guard let measurementID,
          let index = appModel.volumeMeasurements.firstIndex(where: { $0.id == measurementID }),
          let pointID = appModel.volumeMeasurements[index].addPoint(
            at: position,
            physicalExtent: extent
          ) else { return }
    appModel.selectedVolumeMeasurementID = measurementID
    appModel.selectedVolumeMeasurementPointID = pointID
    measurementDragMeasurementID = measurementID
    measurementDragPointID = pointID
    sharePlay.synchronizeMeasurements()
  }

  private func updateMeasurementInteraction(update: RenderDragUpdate) {
    if measurementDragPointID == nil { beginMeasurementInteraction(update: update) }
    guard let screenPosition = normalizedPosition(for: update),
          let measurementID = measurementDragMeasurementID,
          let pointID = measurementDragPointID,
          let index = appModel.volumeMeasurements.firstIndex(where: { $0.id == measurementID }),
          let point = appModel.volumeMeasurements[index].points.first(where: { $0.id == pointID }),
          let position = appModel.markerPositionHandler?(screenPosition, point.position),
          let extent = appModel.activeDatasetMetadata?.physicalExtentMeters else { return }
    appModel.volumeMeasurements[index].setPoint(
      id: pointID,
      position: position,
      physicalExtent: extent
    )
    sharePlay.synchronizeMeasurements()
  }

  private func moveSelectedMeasurementPointInDepth(by delta: CGFloat) {
    guard delta != 0,
          let measurementID = appModel.selectedVolumeMeasurementID,
          let pointID = appModel.selectedVolumeMeasurementPointID,
          let index = appModel.volumeMeasurements.firstIndex(where: { $0.id == measurementID }),
          let point = appModel.volumeMeasurements[index].points.first(where: { $0.id == pointID }),
          let position = appModel.markerDepthAdjustmentHandler?(
            point.position,
            Float(delta) * markerDepthScrollSensitivity
          ),
          let extent = appModel.activeDatasetMetadata?.physicalExtentMeters else { return }
    appModel.volumeMeasurements[index].setPoint(
      id: pointID,
      position: position,
      physicalExtent: extent
    )
    sharePlay.synchronizeMeasurements()
  }

  private var measurementLabels: some View {
    GeometryReader { proxy in
      ForEach(appModel.measurementScreenLabels) { label in
        Text(label.text)
          .font(.caption2.monospacedDigit())
          .padding(.horizontal, 5)
          .padding(.vertical, 2)
          .foregroundStyle(.white)
          .background(
            Color(
              red: Double(label.color.x),
              green: Double(label.color.y),
              blue: Double(label.color.z)
            ).opacity(0.82),
            in: Capsule()
          )
          .position(
            x: CGFloat(label.position.x) * proxy.size.width,
            y: CGFloat(label.position.y) * proxy.size.height
          )
      }
    }
    .allowsHitTesting(false)
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

  private func rotateModel(to current: CGPoint, in viewSize: CGSize) {
    guard viewSize.width > 0,
          viewSize.height > 0,
          let start = arcballStartLocation,
          let startOrientation = arcballStartOrientation else { return }

    let startVector = arcballVector(at: start, in: viewSize)
    let currentVector = arcballVector(at: current, in: viewSize)
    let rotation = quaternionRotating(from: startVector, to: currentVector)
    renderingParameters.orientation = simd_normalize(rotation * startOrientation)
  }

  private func arcballVector(at location: CGPoint, in viewSize: CGSize) -> SIMD3<Float> {
    let radius = Float(max(1, min(viewSize.width, viewSize.height) * 0.5))
    var vector = SIMD3<Float>(
      (Float(location.x) - Float(viewSize.width) * 0.5) / radius,
      (Float(location.y) - Float(viewSize.height) * 0.5) / radius,
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

  private func rotateModelIncrementally(by delta: CGSize) {
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
