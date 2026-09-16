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
#define VOLUME_SHADER_USES_MARKER_TEXTURES 1
#define VOLUME_SHADER_REVERSED_DEPTH 0

#include "VolumeRaycaster.metal"

struct ScreenVolumeMarkerVaryings {
  float4 position [[position]];
  float3 worldPosition;
  float3 worldNormal;
  float3 eyePosition;
};

vertex ScreenVolumeMarkerVaryings screenVolumeMarkerVertex(
  uint vertexId [[vertex_id]],
  device const Vertex* vertices [[buffer(VertexBufferIndexMeshPositions)]],
  constant float4x4 &viewProjection [[buffer(20)]],
  constant float4x4 &modelMatrix [[buffer(21)]],
  constant float3 &eyePosition [[buffer(22)]])
{
  float3 local = vertices[vertexId].position;
  float4 world = modelMatrix * float4(local, 1.0);

  ScreenVolumeMarkerVaryings out;
  out.position = viewProjection * world;
  out.worldPosition = world.xyz;
  out.worldNormal = normalize((modelMatrix * float4(local, 0.0)).xyz);
  out.eyePosition = eyePosition;
  return out;
}

fragment float4 screenVolumeMarkerFragment(
  ScreenVolumeMarkerVaryings in [[stage_in]],
  constant float4 &markerColor [[buffer(23)]])
{
  float3 normal = normalize(in.worldNormal);
  float3 lightDirection = normalize(in.eyePosition - in.worldPosition);
  float diffuse = max(dot(normal, lightDirection), 0.0);
  return float4(markerColor.rgb * (0.28 + 0.72 * diffuse), markerColor.a);
}

struct ScreenMarkerCompositeVaryings {
  float4 position [[position]];
};

struct ScreenMarkerCompositeOut {
  float4 color [[color(0)]];
  float depth [[depth(any)]];
};

vertex ScreenMarkerCompositeVaryings screenMarkerCompositeVertex(uint vertexId [[vertex_id]]) {
  float2 positions[6] = {
    float2(-1.0, -1.0), float2( 1.0, -1.0), float2(-1.0,  1.0),
    float2( 1.0, -1.0), float2( 1.0,  1.0), float2(-1.0,  1.0)
  };
  ScreenMarkerCompositeVaryings out;
  out.position = float4(positions[vertexId], 0.5, 1.0);
  return out;
}

fragment ScreenMarkerCompositeOut screenMarkerCompositeFragment(
  ScreenMarkerCompositeVaryings in [[stage_in]],
  texture2d<float> markerColorTexture [[texture(TextureIndexMarkerColor)]],
  depth2d<float> markerDepthTexture [[texture(TextureIndexMarkerDepth)]])
{
  uint2 pixel = uint2(in.position.xy);
  if (pixel.x >= markerColorTexture.get_width() || pixel.y >= markerColorTexture.get_height()) {
    discard_fragment();
  }

  float depth = markerDepthTexture.read(pixel);
  float4 color = markerColorTexture.read(pixel);
  if (depth >= 1.0 || color.a <= 0.0) {
    discard_fragment();
  }

  ScreenMarkerCompositeOut out;
  out.color = color;
  out.depth = depth;
  return out;
}
