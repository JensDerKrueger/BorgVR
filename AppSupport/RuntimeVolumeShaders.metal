//
//  RuntimeVolumeShaders.metal
//
//  Runtime-compiled volume renderer entry points for iOS and macOS.
//

#define VOLUME_VERTEX_SHADER_NAME volumeVertexShader
#define VOLUME_FRAGMENT_SHADER_TF_NAME volumeFragmentShaderTF
#define VOLUME_FRAGMENT_SHADER_TF_LIGHTING_NAME volumeFragmentShaderTFLighting
#define VOLUME_FRAGMENT_SHADER_ISO_NAME volumeFragmentShaderIso
#define VOLUME_FRAGMENT_SHADER_BRICK_VIS_NAME volumeFragmentShaderBrickVis
#define VOLUME_SHADER_USES_AMPLIFICATION 0

#include "VolumeRaycaster.metal"
