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
require_file AppSupport/SharePlayCoordinator.swift
require_file AppSupport/BorgVRSharePlaySessionEngine.swift
require_file macOSApp/MacSharePlayPlatformAdapter.swift
require_file iOSApp/iOSSharePlayPlatformAdapter.swift
forbid_path macOSApp/SharePlayCoordinator.swift
forbid_path iOSApp/SharePlayCoordinator.swift
require_pattern 'BorgVRRenderSnapshotStore' AppSupport/BorgVRSession.swift
require_pattern 'BorgVRFrameSnapshot' VisionApp/VisionBorgVRSession.swift
require_pattern 'revision: evaluationState\.revision &\+ 1' BORGVR-Render/VolumeAtlas/AsyncEmptinessUpdater.swift

# Shared converter UI and conversion implementation.
require_file AppSupport/ConverterView.swift
require_file AppSupport/DicomSlicePreview.swift
forbid_path macOSApp/ConverterView.swift
forbid_path macOSServer/ConverterView.swift
forbid_path macOSApp/DicomSlicePreview.swift
forbid_path macOSServer/DicomSlicePreview.swift
require_pattern 'BorgVRVolumeConversionService\.convert' AppSupport/ConverterView.swift
require_pattern 'BorgVRVolumeConversionService\.convert' macOSApp/BorgVRScriptRunner.swift
require_pattern 'BorgVRVolumeConversionService\.convert' TerminalConverterApp/main.swift
require_pattern 'BorgVRVolumeConversionService\.convert' iOSApp/ConverterView.swift
require_pattern 'BorgVRVolumeConversionService\.convert' VisionApp/ConverterView.swift

# Shared dataset-open workflow and catalog.
require_file AppSupport/DatasetOpenWorkflow.swift
require_file AppSupport/OpenDatasetView.swift
require_file AppSupport/WaitingView.swift
forbid_path macOSApp/OpenDatasetView.swift
forbid_path iOSApp/OpenDatasetView.swift
forbid_path macOSApp/WaitingView.swift
forbid_path iOSApp/WaitingView.swift
forbid_path macOSApp/DatasetCatalogService.swift
catalog_count=$(rg -l 'final class DatasetCatalogService' --glob '*.swift' | wc -l | tr -d ' ')
[ "$catalog_count" -eq 1 ] || fail "expected one DatasetCatalogService, found $catalog_count"

# Logger layering and removed dead implementations.
require_file AppSupport/GUILogger.swift
forbid_pattern 'class (OSLogger|HTMLLogger|JSONLogger|CSVLogger)' BORGVR-IO/Logger.swift
forbid_pattern 'GUILogger' BORGVR-IO/Logger.swift
forbid_pattern 'shiftedHue' VisionApp/ImmersiveInteraction.swift
forbid_pattern 'synchronizeLighting|synchronizeTransform' macOSApp/BorgVRScriptRunner.swift
forbid_pattern 'establishInitialScreenView' AppSupport/SharePlayCoordinator.swift

# Removed backup assets and centralized screen interaction constants.
forbid_path Assets.xcassets.disabled
require_pattern 'enum ScreenInteractionLimits' AppSupport/RenderingParameters.swift
require_pattern 'ScreenInteractionLimits\.modelScale' macOSApp/RenderView.swift
require_pattern 'ScreenInteractionLimits\.modelScale' iOSApp/RenderView.swift
require_pattern 'ScreenInteractionLimits\.transferSmoothWidth' macOSApp/RenderView.swift
require_pattern 'ScreenInteractionLimits\.transferSmoothWidth' iOSApp/RenderView.swift

printf 'Refactoring structure tests passed\n'
