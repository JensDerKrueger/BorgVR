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

#include "../AppSupport/VolumeRaycaster.metal"
#include "../AppSupport/VisionHUDShaders.metal"
