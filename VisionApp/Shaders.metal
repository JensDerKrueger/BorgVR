//
//  Shaders.metal
//
//  visionOS volume renderer and HUD shader entry points.
//

#define VOLUME_VERTEX_SHADER_NAME vertexShader
#define VOLUME_FRAGMENT_SHADER_TF_NAME fragmentShaderTF
#define VOLUME_FRAGMENT_SHADER_TF_LIGHTING_NAME fragmentShaderTFLighting
#define VOLUME_FRAGMENT_SHADER_ISO_NAME fragmentShaderIso
#define VOLUME_FRAGMENT_SHADER_BRICK_VIS_NAME fragmentShaderBrickVis
#define VOLUME_SHADER_USES_AMPLIFICATION 1
#ifndef VOLUME_SHADER_USES_RATE_MAP
#define VOLUME_SHADER_USES_RATE_MAP 1
#endif
#define VOLUME_SHADER_USES_MARKER_TEXTURES 1
#define VOLUME_SHADER_WRITES_REPROJECTION_DEPTH 1

#include "../AppSupport/Rendering/Shaders/VolumeRaycaster.metal"
#include "../AppSupport/Rendering/Shaders/VisionInteractionShaders.metal"

// Reduce distortions in low-FPS scenarios by keeping rasterized bounding-box depth.
fragment void fragmentShaderBoundingBoxDepth() {}
