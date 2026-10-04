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
  device const Vertex* normals [[buffer(24)]],
  constant float4x4 &viewProjection [[buffer(20)]],
  constant float4x4 &modelMatrix [[buffer(21)]],
  constant float3 &eyePosition [[buffer(22)]])
{
  float3 local = vertices[vertexId].position;
  float4 world = modelMatrix * float4(local, 1.0);

  ScreenVolumeMarkerVaryings out;
  out.position = viewProjection * world;
  out.worldPosition = world.xyz;
  out.worldNormal = normalize((modelMatrix * float4(normals[vertexId].position, 0.0)).xyz);
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

struct ScreenMeasurementPointInstance {
  float4 centerAndRadius;
  float4 color;
};

struct ScreenMeasurementPointVaryings {
  float4 position [[position]];
  float2 localPosition;
  float4 color;
};

vertex ScreenMeasurementPointVaryings screenMeasurementPointVertex(
  uint vertexId [[vertex_id]],
  uint instanceId [[instance_id]],
  device const ScreenMeasurementPointInstance *points [[buffer(25)]],
  constant float4x4 &viewProjection [[buffer(20)]],
  constant float4x4 &modelMatrix [[buffer(21)]],
  constant float2 &viewportSize [[buffer(26)]])
{
  const float2 corners[6] = {
    float2(-1.0, -1.0), float2( 1.0, -1.0), float2(-1.0,  1.0),
    float2( 1.0, -1.0), float2( 1.0,  1.0), float2(-1.0,  1.0)
  };
  ScreenMeasurementPointInstance point = points[instanceId];
  float4 clipPosition = viewProjection * modelMatrix * float4(point.centerAndRadius.xyz, 1.0);
  float2 safeViewportSize = max(viewportSize, float2(1.0));
  clipPosition.xy += corners[vertexId] * point.centerAndRadius.w * 2.0 /
    safeViewportSize * clipPosition.w;

  ScreenMeasurementPointVaryings out;
  out.position = clipPosition;
  out.localPosition = corners[vertexId];
  out.color = point.color;
  return out;
}

fragment float4 screenMeasurementPointFragment(
  ScreenMeasurementPointVaryings in [[stage_in]])
{
  float distanceFromCenter = length(in.localPosition);
  float antialiasWidth = max(fwidth(distanceFromCenter), 0.015);
  float ring = smoothstep(0.68 - antialiasWidth, 0.68 + antialiasWidth, distanceFromCenter) *
    (1.0 - smoothstep(0.94 - antialiasWidth, 0.94 + antialiasWidth, distanceFromCenter));
  float dot = 1.0 - smoothstep(0.20 - antialiasWidth, 0.20 + antialiasWidth, distanceFromCenter);
  float coverage = max(ring, dot);
  if (coverage < 0.01) {
    discard_fragment();
  }
  return float4(in.color.rgb, in.color.a * coverage);
}

struct ScreenSceneMeshVertex {
  float3 position;
  float3 normal;
  float2 texcoord;
  float3 color;
};

struct ScreenSceneMeshVaryings {
  float4 position [[position]];
  float3 worldPosition;
  float3 worldNormal;
  float2 texcoord;
  float3 color;
  float3 eyePosition;
};

vertex ScreenSceneMeshVaryings screenSceneMeshVertex(
  uint vertexId [[vertex_id]],
  device const ScreenSceneMeshVertex* vertices [[buffer(VertexBufferIndexMeshPositions)]],
  constant float4x4 &viewProjection [[buffer(20)]],
  constant float4x4 &modelMatrix [[buffer(21)]],
  constant float3 &eyePosition [[buffer(22)]],
  constant float4x4 &normalMatrix [[buffer(24)]])
{
  ScreenSceneMeshVertex meshVertex = vertices[vertexId];
  float4 world = modelMatrix * float4(meshVertex.position, 1.0);

  ScreenSceneMeshVaryings out;
  out.position = viewProjection * world;
  out.worldPosition = world.xyz;
  out.worldNormal = normalize((normalMatrix * float4(meshVertex.normal, 0.0)).xyz);
  out.texcoord = meshVertex.texcoord;
  out.color = meshVertex.color;
  out.eyePosition = eyePosition;
  return out;
}

fragment float4 screenSceneMeshFragment(
  ScreenSceneMeshVaryings in [[stage_in]],
  constant float3 &baseColor [[buffer(23)]],
  texture2d<float> colorTexture [[texture(TextureIndexSceneMeshColor)]])
{
  constexpr sampler colorSampler(filter::linear, mip_filter::linear, address::repeat);
  float3 textureColor = colorTexture.sample(colorSampler, in.texcoord).rgb;
  float3 normal = normalize(in.worldNormal);
  float3 lightDirection = normalize(in.eyePosition - in.worldPosition);
  float diffuse = max(dot(normal, lightDirection), 0.0);
  float3 color = baseColor * in.color * textureColor;
  return float4(color * (0.22 + 0.78 * diffuse), 1.0);
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
  if (depth <= 0.0 || color.a <= 0.0) {
    discard_fragment();
  }

  ScreenMarkerCompositeOut out;
  out.color = color;
  out.depth = depth;
  return out;
}
