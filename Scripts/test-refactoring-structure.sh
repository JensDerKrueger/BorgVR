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
require_pattern 'BorgVRFrameSnapshot' VisionApp/VisionBorgVRSession.swift
require_pattern 'revision: evaluationState\.revision &\+ 1' BORGVR-Render/VolumeAtlas/AsyncEmptinessUpdater.swift

# The visionOS renderer follows the same one-file naming convention as the screen renderers.
require_file VisionApp/Rendering/VisionVolumeRenderer.swift
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

# Shared converter UI and conversion implementation.
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
