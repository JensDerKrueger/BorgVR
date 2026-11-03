#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

fail() {
  printf 'Structure regression: %s\n' "$1" >&2
  exit 1
}

require_file() {
  [ -f "$1" ] || fail "missing $1"
}

forbid_path() {
  [ ! -e "$1" ] || fail "obsolete path returned: $1"
}

require_pattern() {
  pattern=$1
  file=$2
  rg -q "$pattern" "$file" || fail "$file no longer contains $pattern"
}

forbid_pattern() {
  pattern=$1
  file=$2
  if rg -q "$pattern" "$file"; then
    fail "$file contains obsolete symbol $pattern"
  fi
}

# Shared SharePlay coordination and immutable render snapshots.
require_file AppSupport/SharePlay/SharePlayCoordinator.swift
require_file AppSupport/SharePlay/BorgVRSharePlaySessionEngine.swift
require_file macOSApp/MacSharePlayPlatformAdapter.swift
require_file iOSApp/iOSSharePlayPlatformAdapter.swift
forbid_path macOSApp/SharePlayCoordinator.swift
forbid_path iOSApp/SharePlayCoordinator.swift
require_pattern 'BorgVRRenderSnapshotStore' AppSupport/Application/BorgVRSession.swift
require_pattern 'volumeBrush\.close\(\)' AppSupport/Application/AppModel.swift
require_pattern 'BorgVRFrameSnapshot' VisionApp/VisionBorgVRSession.swift
require_pattern 'revision: evaluationState\.revision &\+ 1' BORGVR-Render/VolumeAtlas/AsyncEmptinessUpdater.swift
require_pattern 'isItalic: appModel.isDatasetStreaming' macOSApp/RenderControlsPanel.swift
require_pattern 'window.configuration.titleFormat.isItalic' macOSApp/DockablePanelViews.swift
require_pattern 'titleFormat = model.configuration.titleFormat' macOSApp/NativePanelToolbar.swift
forbid_pattern 'isDatasetStreaming|titleIsLoading' macOSApp/PanelWindow.swift
forbid_pattern 'isDatasetStreaming|titleIsLoading' macOSApp/NativePanelToolbar.swift

# In-place TF painting must publish a snapshot without a channel-selection change.
for file in iOSApp/RenderView.swift macOSApp/RenderView.swift; do
  require_pattern 'session.commitExternalMutation\(source: \.userInterface, domain: \.transferFunction\)' "$file"
done

# Screen projection is local, persistent, recordable and available through automation.
require_file AppSupport/Rendering/VolumeBoundingBoxRenderer.swift
for file in AppSupport/Rendering/VolumeRendererPipeline.swift VisionApp/Rendering/VisionOpaqueGeometryRenderer.swift; do
  require_pattern 'boundingBoxRenderer.render' "$file"
done
for file in macOSApp/SettingsView.swift iOSApp/SettingsView.swift VisionApp/SettingsView.swift macOSApp/macOSApp.swift; do
  require_pattern 'session.perform\(\.setBoundingBox' "$file"
done
require_pattern 'case "set_bounding_box"' BORGVR-Services/BorgVRMCPServer.swift
require_pattern '^showboundingbox\(' Scripts/borgvr.gsccommands
require_pattern 'case setScreenProjection' AppSupport/Application/BorgVRSession.swift
for file in macOSApp/SettingsView.swift iOSApp/SettingsView.swift macOSApp/macOSApp.swift; do
  require_pattern 'session.perform\(\.setScreenProjection' "$file"
done
for command in setfieldofview setparallelprojection; do
  require_pattern "$command" AppSupport/Application/BorgVRSession.swift
  require_pattern "$command" macOSApp/BorgVRScriptRunner.swift
  require_pattern "^$command\\(" Scripts/borgvr.gsccommands
  require_pattern "$command" html/gsc.html
done
require_pattern 'case "set_screen_projection"' BORGVR-Services/BorgVRMCPServer.swift
require_pattern 'tool\("set_screen_projection"' BORGVR-Services/BorgVRMCPServer.swift
require_pattern 'session.perform\(\.setScreenProjection' AppSupport/Automation/BorgVRScreenCommandService.swift

# New render controls must stay executable, queryable, and recordable, not raw UI mutations.
for command in showbricks showresidentbricks showemptybricks showmissingbricks \
  setsubbrickskipping setopacityadaptivesampling setalphaepsilon; do
  require_pattern "\"$command[\" ]" AppSupport/Application/BorgVRSession.swift
  require_pattern "\"$command\"" macOSApp/BorgVRScriptRunner.swift
  require_pattern "^$command\\(" Scripts/borgvr.gsccommands
  require_pattern "$command" html/gsc.html
done
for command in set_brick_visualization set_render_optimizations; do
  require_pattern "case \"$command\"" BORGVR-Services/BorgVRMCPServer.swift
  require_pattern "tool\\(\"$command\"" BORGVR-Services/BorgVRMCPServer.swift
  require_pattern "$command" html/mcp.html
done
for file in AppSupport/Automation/BorgVRScreenCommandService.swift VisionApp/VisionBorgVRCommandService.swift; do
  require_pattern 'renderingOptions: BorgVRMCPRenderingOptions' "$file"
  require_pattern 'session.perform\(\.setBrickVisualization' "$file"
  require_pattern 'session.perform\(\.setRenderOptimizations' "$file"
done
for file in macOSApp/SettingsView.swift iOSApp/SettingsView.swift VisionApp/SettingsView.swift; do
  require_pattern 'session.perform\(\.setRenderOptimizations' "$file"
  forbid_pattern 'isOn: \$(appSettings|storedAppModel)\.(subbrickSkipping|opacityAdaptiveSampling)' "$file"
  forbid_pattern 'value: \$(appSettings|storedAppModel)\.alphaEpsilon' "$file"
done
require_pattern 'inferredSettingsCommands' AppSupport/Application/BorgVRSession.swift
require_pattern 'session.perform\(\.setBrickVisualization' VisionApp/ProfileView.swift
require_pattern 'session.perform\(\.setBrickVisualization' macOSApp/macOSApp.swift
require_pattern 'session.perform\(\.setRenderOptimizations' macOSApp/macOSApp.swift

# The visionOS orchestrator delegates resource ownership and non-volume drawing.
require_file VisionApp/Rendering/VisionVolumeRenderer.swift
require_file VisionApp/Rendering/VisionOpaqueGeometryRenderer.swift
require_file VisionApp/Rendering/VisionFrameResources.swift
require_file VisionApp/Rendering/VisionRenderLoopLifecycle.swift
require_pattern 'opaqueGeometryRenderer.render' VisionApp/Rendering/VisionVolumeRenderer.swift
forbid_pattern 'func draw(SceneMeshes|OpaqueGeometry|ScreenViewLabels)' VisionApp/Rendering/VisionVolumeRenderer.swift
forbid_pattern 'Task.sleep' VisionApp/Rendering/VisionRenderLoopLifecycle.swift
require_file VisionApp/VisionVolumeRendererBootstrap.swift
forbid_path VisionApp/Rendering/RendererVariables.swift
forbid_path VisionApp/Rendering/RendererResourceInit.swift
forbid_path VisionApp/Rendering/RendererLoop.swift
forbid_path VisionApp/Rendering/RendererSetup.swift
forbid_path VisionApp/ImmersiveRendererBootstrap.swift
require_pattern 'final actor VisionVolumeRenderer' VisionApp/Rendering/VisionVolumeRenderer.swift
require_pattern 'VisionVolumeRenderer\.startRenderLoop' VisionApp/VisionVolumeRendererBootstrap.swift
forbid_pattern 'nonisolated\(unsafe\).*autoRotationAngle' VisionApp/Rendering/VisionVolumeRenderer.swift
forbid_pattern 'nonisolated\(unsafe\).*activeOversampling' VisionApp/Rendering/VisionVolumeRenderer.swift
require_pattern 'VisionRendererPerformanceMailbox' VisionApp/Rendering/VisionVolumeRenderer.swift
require_pattern 'rotationCaptureRequestID' VisionApp/Rendering/VisionVolumeRenderer.swift

# Render performance uses completed Metal GPU timestamps with a tested fallback.
require_pattern 'let timer = GPUFrameTimer\(\)' BORGVR-Render/Screen/ScreenVolumeRendererCore.swift
require_pattern 'let timer = GPUFrameTimer\(\)' VisionApp/VisionVolumeRendererBootstrap.swift
require_pattern 'timer\.recordCompletedFrame\(commandBuffer\)' VisionApp/Rendering/VisionVolumeRenderer.swift
require_pattern 'timer\.recordCompletedFrame\(frame\.commandBuffer\)' BORGVR-Render/Screen/ScreenVolumeRendererCore.swift
forbid_pattern 'CPUFrameTimer' BORGVR-Render/Screen/ScreenVolumeRendererCore.swift
forbid_pattern 'CPUFrameTimer' VisionApp/Rendering/VisionVolumeRenderer.swift

# Screen screenshot timeouts cancel their renderer request and reject stale GPU completions.
require_file AppSupport/Automation/ScreenScreenshotRequestQueue.swift
require_pattern 'cancelRenderScreenshot' AppSupport/Application/AppModel.swift
require_pattern 'cancelRenderScreenshot' AppSupport/Automation/BorgVRScreenCommandService.swift
forbid_pattern 'pendingScreenshot(URL|AccessURL|Completion)' macOSApp/MacVolumeRenderer.swift
forbid_pattern 'pendingScreenshot(URL|Completion)' iOSApp/MobileVolumeRenderer.swift

# Entering Edit mode never opens its settings; its separate tool button owns presentation.
forbid_pattern 'if mode == \.volumeEditing.*presentedSheet' iOSApp/RenderView.swift
require_pattern 'toggleToolSheet\(\.volumeBrush\)' iOSApp/RenderView.swift
forbid_pattern 'VolumeBrushControls' VisionApp/PrivateApplicationView.swift
require_pattern 'openWindow\(id: "VolumeBrushEditorView"\)' VisionApp/PrivateApplicationView.swift
require_pattern 'WindowGroup\(id: "VolumeBrushEditorView"\)' VisionApp/VisionApp.swift
require_pattern 'dismissWindow\(id: "VolumeBrushEditorView"\)' VisionApp/RenderView.swift

# Shared converter UI and conversion implementation.
require_file BORGVR-Services/BorgVRAutoImporter.swift
require_file TerminalServerApp/BorgVRAutoImporter.swift
require_pattern 'BorgVRAutoImporter\(' TerminalServerApp/main.swift
require_pattern 'BorgVRAutoImporter\(' macOSServer/ServerView.swift
require_pattern 'BorgVRAutomaticVolumeConversion.convert' BORGVR-Services/BorgVRAutoImporter.swift
for format in NRRD QVIS I3D DICOM ZARR PVM Mesh; do
  [ -d "BORGVR-IO/Importers/$format" ] || fail "missing importer directory $format"
done
require_file BORGVR-IO/Importers/VolumeFileParser.swift
require_file BORGVR-IO/Importers/BorgVRVolumeConversionService.swift
forbid_path BORGVR-IO/VolumeFileParser.swift
forbid_path BORGVR-IO/DICOM.swift
forbid_path BORGVR-IO/NRRDParser.swift
forbid_path BORGVR-IO/ZarrParser.swift
require_pattern 'case zarrDirectory' AppSupport/UI/FilePickerView.swift
require_pattern 'filePickerMode = \.zarrDirectory' iOSApp/ConverterView.swift
require_pattern 'filePickerMode = \.zarrDirectory' VisionApp/ConverterView.swift
require_file AppSupport/Datasets/ConverterView.swift
require_file AppSupport/Datasets/DicomSlicePreview.swift
forbid_path macOSApp/ConverterView.swift
forbid_path macOSServer/ConverterView.swift
forbid_path macOSApp/DicomSlicePreview.swift
forbid_path macOSServer/DicomSlicePreview.swift
require_pattern 'BorgVRVolumeConversionService\.convert' AppSupport/Datasets/ConverterView.swift
require_pattern 'BorgVRVolumeConversionService\.convert' macOSApp/BorgVRScriptRunner.swift
require_pattern 'BorgVRVolumeConversionService\.convert' TerminalConverterApp/main.swift
require_pattern 'BorgVRVolumeConversionService\.convert' iOSApp/ConverterView.swift
require_pattern 'BorgVRVolumeConversionService\.convert' VisionApp/ConverterView.swift

# Shared dataset-open workflow and catalog.
require_file AppSupport/Datasets/DatasetOpenWorkflow.swift
require_file AppSupport/Datasets/OpenDatasetView.swift
require_file AppSupport/Datasets/WaitingView.swift
# Keep bundled SharePlay datasets distinct from writable local files, so their
# edits never resolve to a sidecar inside the signed app bundle.
require_pattern 'func findLocalDataset.*source: RuntimeAppModel.DatasetSource' VisionApp/FileOperations.swift
require_pattern 'return \(match\.1, match\.2\)' VisionApp/FileOperations.swift
require_pattern 'source: localDataset\.source' VisionApp/GroupActivities.swift
require_pattern 'case \.builtIn: editDatasetURL = nil' VisionApp/VisionVolumeRendererBootstrap.swift
forbid_path macOSApp/OpenDatasetView.swift
forbid_path iOSApp/OpenDatasetView.swift
forbid_path macOSApp/WaitingView.swift
forbid_path iOSApp/WaitingView.swift
forbid_path macOSApp/DatasetCatalogService.swift
catalog_count=$(rg -l 'final class DatasetCatalogService' --glob '*.swift' | wc -l | tr -d ' ')
[ "$catalog_count" -eq 1 ] || fail "expected one DatasetCatalogService, found $catalog_count"

# Logger layering and removed dead implementations.
require_file AppSupport/UI/GUILogger.swift
forbid_pattern 'class (OSLogger|HTMLLogger|JSONLogger|CSVLogger)' BORGVR-IO/Logger.swift
forbid_pattern 'GUILogger' BORGVR-IO/Logger.swift
forbid_pattern 'shiftedHue' VisionApp/ImmersiveInteraction.swift
forbid_pattern 'synchronizeLighting|synchronizeTransform' macOSApp/BorgVRScriptRunner.swift
forbid_pattern 'establishInitialScreenView' AppSupport/SharePlay/SharePlayCoordinator.swift
forbid_pattern 'toggleInteractionMode|onDoubleTap' macOSApp/RenderView.swift
forbid_pattern 'onDoubleTap' macOSApp/MacMetalView.swift
for file in \
  AppSupport/SharePlay/SharePlayCoordinator.swift \
  macOSApp/macOSApp.swift \
  iOSApp/BorgVRMobileApp.swift \
  VisionApp/AppModels/SharedAppModel.swift \
  VisionApp/GroupActivities.swift \
  VisionApp/VisionApp.swift; do
  forbid_pattern 'hasObservedGroupSession' "$file"
done

# Removed backup assets and centralized screen interaction constants.
forbid_path Assets.xcassets.disabled
forbid_path macOSApp/MacMeasurementView.jpg
forbid_path macOSApp/borgvr.png
require_file macOSApp/Assets.xcassets/borgvr.imageset/borgvr.png
require_pattern 'enum ScreenInteractionLimits' AppSupport/Rendering/RenderingParameters.swift
require_pattern 'ScreenInteractionLimits\.modelScale' macOSApp/RenderView.swift
require_pattern 'ScreenInteractionLimits\.modelScale' iOSApp/RenderView.swift
require_pattern 'ScreenInteractionLimits\.transferSmoothWidth' macOSApp/RenderView.swift
require_pattern 'ScreenInteractionLimits\.transferSmoothWidth' iOSApp/RenderView.swift

# AppSupport mirrors its stable responsibility boundaries in both the file system and Xcode.
for directory in Annotations Application Automation Datasets Rendering SharePlay UI Web; do
  [ -d "AppSupport/$directory" ] || fail "missing AppSupport/$directory"
done
require_file AppSupport/Rendering/Shaders/ShaderTypes.h
require_pattern 'path = Application;' BorgVR.xcodeproj/project.pbxproj
require_pattern 'path = Shaders;' BorgVR.xcodeproj/project.pbxproj
require_pattern 'AppSupport/Rendering/Shaders/ShaderTypes\.h' BorgVR.xcodeproj/project.pbxproj
forbid_path AppSupport/AppModel.swift
forbid_path AppSupport/ShaderTypes.h

printf 'Refactoring structure tests passed\n'
