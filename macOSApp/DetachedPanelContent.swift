import SwiftUI

struct DetachedPanelContent: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var renderingParameters: RenderingParameters
  @EnvironmentObject private var storedAppModel: StoredAppModel
  @EnvironmentObject private var docking: DockingController
  @EnvironmentObject private var sharePlay: SharePlayCoordinator
  @EnvironmentObject private var session: ScreenBorgVRSession

  let panel: DockablePanelID

  var body: some View {
    switch panel {
      case .renderControls:
        DetachedDockablePanel(panel: panel, minWidth: 620, minHeight: 220) {
          DockableEditorPanel(panel: panel, detached: true) { RenderControlsPanel() }
        }

      case .transferFunctionEditor:
        DetachedDockablePanel(panel: panel, minWidth: 760, minHeight: 260) {
          if renderingParameters.renderMode == .isoValue {
            unavailableEditorMessage
          } else {
            DockableEditorPanel(panel: panel, detached: true) {
              TransferFunctionEditorView(
                usesPanelBackground: false,
                usesFlexibleCanvasHeight: true,
                catalogDirectoryURLs: transferFunctionCatalogDirectoryURLs,
                onMutation: {
                  session.commitExternalMutation(
                    source: .userInterface,
                    domain: .transferFunction
                  )
                }
              )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }

      case .isoEditor:
        DetachedDockablePanel(panel: panel, minWidth: 520, minHeight: 150) {
          if renderingParameters.renderMode == .isoValue {
            DockableEditorPanel(panel: panel, detached: true) {
              IsovalueEditorView(usesPanelBackground: false, showsTitle: false)
            }
          } else {
            unavailableEditorMessage
          }
        }

      case .markerEditor:
        DetachedDockablePanel(panel: panel, minWidth: 480, minHeight: 520) {
          DockableEditorPanel(panel: panel, detached: true) {
            MacMarkerView()
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

      case .measurementEditor:
        DetachedDockablePanel(panel: panel, minWidth: 480, minHeight: 520) {
          DockableEditorPanel(panel: panel, detached: true) {
            MacMeasurementView()
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

      case .lightingEditor:
        DetachedDockablePanel(panel: panel, minWidth: 380, minHeight: 430) {
          DockableEditorPanel(panel: panel, detached: true) {
            LightingEditorView(
              renderMode: renderingParameters.renderMode,
              lightDirection: $renderingParameters.lightDirection,
              ambientLightColor: $renderingParameters.ambientLightColor,
              diffuseLightColor: $renderingParameters.diffuseLightColor,
              specularLightColor: $renderingParameters.specularLightColor,
              usesPanelBackground: false,
              showsTitle: false,
              onChange: {
                session.commitExternalMutation(source: .userInterface, domain: .visualization)
                sharePlay.synchronize(kind: .stateOnly)
              },
              onCommit: sharePlay.flushSynchronization,
              onClose: nil
            )
            .equatable()
          }
        }
      case .volumeBrushEditor:
        DetachedDockablePanel(panel: panel, minWidth: 360, minHeight: 380) {
          DockableEditorPanel(panel: panel, detached: true) {
            VolumeBrushControls(model: appModel.volumeBrush)
          }
        }
    }
  }

  private var unavailableEditorMessage: some View {
    VStack(spacing: 12) {
      Text("This editor is not available in the current render mode.")
        .foregroundStyle(.secondary)
      DockToggleButton(panel: panel)
    }
    .padding()
  }

  private var transferFunctionCatalogDirectoryURLs: [URL] {
    [storedAppModel.resolvedDataDirectoryURL()]
  }
}
