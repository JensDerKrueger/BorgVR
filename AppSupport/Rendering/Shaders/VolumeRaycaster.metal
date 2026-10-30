//
//  VolumeRaycaster.metal
//
//  Shared volume raycaster implementation for iOS, macOS, and visionOS.
//

#include <metal_stdlib>
#include <simd/simd.h>

// Local includes are expanded by RuntimeMetalShaderLoader before runtime compilation.
// Xcode resolves the same includes when this file is included by the visionOS shader.
#import "ShaderTypes.h"
#include "VolumeAtlas.h"
#include "Helper.h"

using namespace metal;

#ifndef VOLUME_SHADER_USES_AMPLIFICATION
#define VOLUME_SHADER_USES_AMPLIFICATION 0
#endif

#ifndef VOLUME_SHADER_USES_RATE_MAP
#define VOLUME_SHADER_USES_RATE_MAP 0
#endif

#ifndef VOLUME_SHADER_USES_MARKER_TEXTURES
#define VOLUME_SHADER_USES_MARKER_TEXTURES 0
#endif

#ifndef VOLUME_SHADER_WRITES_REPROJECTION_DEPTH
#define VOLUME_SHADER_WRITES_REPROJECTION_DEPTH 0
#endif

#if VOLUME_SHADER_USES_AMPLIFICATION
#define VOLUME_SHADER_AMP_PARAMETER , ushort amp_id [[amplification_id]]
#define VOLUME_SHADER_UNIFORM_INDEX amp_id
#else
#define VOLUME_SHADER_AMP_PARAMETER
#define VOLUME_SHADER_UNIFORM_INDEX 0
#endif

#if VOLUME_SHADER_USES_RATE_MAP
#define VOLUME_SHADER_RATE_MAP_PARAMETER , constant rasterization_rate_map_data& rateMapData [[buffer(FragmentBufferIndexRateMap)]]
#define VOLUME_SHADER_RATE_MAP_ARGUMENT , rateMapData
#else
#define VOLUME_SHADER_RATE_MAP_PARAMETER
#define VOLUME_SHADER_RATE_MAP_ARGUMENT
#endif

#if VOLUME_SHADER_USES_MARKER_TEXTURES
#if VOLUME_SHADER_USES_AMPLIFICATION
#define VOLUME_SHADER_MARKER_TEXTURE depth2d_array<float>
#else
#define VOLUME_SHADER_MARKER_TEXTURE depth2d<float>
#endif
#define VOLUME_SHADER_MARKER_PARAMETER , VOLUME_SHADER_MARKER_TEXTURE markerDepthTexture [[texture(TextureIndexMarkerDepth)]]
#define VOLUME_SHADER_MARKER_ARGUMENT , markerDepthTexture
#else
#define VOLUME_SHADER_MARKER_PARAMETER
#define VOLUME_SHADER_MARKER_ARGUMENT
#endif

#ifndef VOLUME_VERTEX_SHADER_NAME
#define VOLUME_VERTEX_SHADER_NAME volumeVertexShader
#endif
#ifndef VOLUME_FRAGMENT_SHADER_TF_NAME
#define VOLUME_FRAGMENT_SHADER_TF_NAME volumeFragmentShaderTF
#endif
#ifndef VOLUME_FRAGMENT_SHADER_TF_LIGHTING_NAME
#define VOLUME_FRAGMENT_SHADER_TF_LIGHTING_NAME volumeFragmentShaderTFLighting
#endif
#ifndef VOLUME_FRAGMENT_SHADER_ISO_NAME
#define VOLUME_FRAGMENT_SHADER_ISO_NAME volumeFragmentShaderIso
#endif
#ifndef VOLUME_FRAGMENT_SHADER_BRICK_VIS_NAME
#define VOLUME_FRAGMENT_SHADER_BRICK_VIS_NAME volumeFragmentShaderBrickVis
#endif

typedef struct {
  /// Clip-space position of the vertex.
  simd_float4 position [[position]];
  /// Exit point of the ray in texture coordinate space (0–1 range).
  simd_float3 exitPoint;
} VertexToFragment;

typedef struct {
  half4 color [[color(0)]];
  float interactionDepth [[color(1)]];
#if VOLUME_SHADER_WRITES_REPROJECTION_DEPTH
  float depth [[depth(any)]];
#endif
} VolumeFragmentOutput;

inline VolumeFragmentOutput volumeFragmentOutput(half4 color) {
  VolumeFragmentOutput out;
  out.color = color;
  out.interactionDepth = -1.0;
#if VOLUME_SHADER_WRITES_REPROJECTION_DEPTH
  out.depth = 0.0;
#endif
  return out;
}

inline float volumePositionDepth(FragmentUniforms uniforms, float3 position) {
  float4 clip = uniforms.textureToClip * float4(position, 1.0);
  return all(isfinite(clip)) && clip.w > 1e-6 ? clip.z / clip.w : -1.0;
}

inline VolumeFragmentOutput volumeFragmentOutput(half4 color,
                                                 FragmentUniforms uniforms,
                                                 float3 interactionPosition) {
  VolumeFragmentOutput out = volumeFragmentOutput(color);
  out.interactionDepth = volumePositionDepth(uniforms, interactionPosition);
#if VOLUME_SHADER_WRITES_REPROJECTION_DEPTH
  // The compositor needs the raycast hit, not the rasterized bounding-box exit.
  out.depth = color.a > 0 ? clamp(out.interactionDepth, 0.0, 1.0) : 0.0;
#endif
  return out;
}

inline VolumeFragmentOutput visibleVolumeOutput(bool stoppedAtOpaqueGeometry,
                                                float4 colorAtOpaqueGeometry,
                                                float4 accumulatedColor,
                                                FragmentUniforms uniforms,
                                                bool hasInteraction,
                                                float3 interactionPosition,
                                                float3 positionAtOpaqueGeometry) {
  half4 color = half4(stoppedAtOpaqueGeometry ? colorAtOpaqueGeometry : accumulatedColor);
  VolumeFragmentOutput out = hasInteraction
    ? volumeFragmentOutput(color, uniforms, interactionPosition)
    : volumeFragmentOutput(color);
#if VOLUME_SHADER_WRITES_REPROJECTION_DEPTH
  // Picking continues behind geometry, but reprojection must follow visible color.
  if (stoppedAtOpaqueGeometry && color.a > 0) {
    out.depth = clamp(volumePositionDepth(uniforms, positionAtOpaqueGeometry), 0.0, 1.0);
  }
#endif
  return out;
}

inline float effectiveOversampling(float baseOversampling,
                                   float4 fragmentPosition,
                                   uint layerIndex
#if VOLUME_SHADER_USES_RATE_MAP
                                   , constant rasterization_rate_map_data& rateMapData
#endif
                                   ) {
#if VOLUME_SHADER_USES_RATE_MAP
  rasterization_rate_map_decoder rateMap(rateMapData);
  float2 physicalPosition = fragmentPosition.xy;
  float2 screenPosition = rateMap.map_physical_to_screen_coordinates(physicalPosition, layerIndex);
  float2 screenPositionX = rateMap.map_physical_to_screen_coordinates(physicalPosition + float2(1.0, 0.0), layerIndex);
  float2 screenPositionY = rateMap.map_physical_to_screen_coordinates(physicalPosition + float2(0.0, 1.0), layerIndex);
  float screenPixelsPerPhysicalPixel = max(length(screenPositionX - screenPosition),
                                           length(screenPositionY - screenPosition));
  float rateScale = sqrt(1.0 / max(screenPixelsPerPhysicalPixel, 1.0));
  return max(baseOversampling * clamp(rateScale, 0.5, 1.0), 0.25);
#else
  return baseOversampling;
#endif
}

inline float hash13(float3 seed) {
  float3 p = fract(seed * 0.1031);
  p += dot(p, p.yzx + 33.33);
  return fract((p.x + p.y) * p.z);
}

inline float raySamplePhase(float3 entryPoint, float3 direction, uint layerIndex) {
  float3 voxelEntry = entryPoint * VOLUME_SIZE;
  float3 voxelDirection = normalize(direction * VOLUME_SIZE);
  return hash13(voxelEntry + voxelDirection * 97.0 + float3(float(layerIndex) * 31.0));
}

inline float samplingPhase(FragmentUniforms uniforms,
                           float3 entryPoint,
                           float3 direction,
                           uint layerIndex,
                           float defaultPhase) {
  return uniforms.sampleJitter > 0.5 ? raySamplePhase(entryPoint, direction, layerIndex) : defaultPhase;
}

inline float distanceFromCameraInNormalizedVolumeSpace(FragmentUniforms uniforms,
                                                       float3 texturePoint) {
  float3 cameraPoint = uniforms.cameraPosInTextureSpaceVoxelScaled - 0.5;
  float3 volumePoint = (texturePoint - 0.5) * VOLUME_SCALE;
  return length(cameraPoint - volumePoint);
}

#if VOLUME_SHADER_USES_MARKER_TEXTURES
inline float markerDepthAtFragment(float4 fragmentPosition,
                                   uint layerIndex,
                                   VOLUME_SHADER_MARKER_TEXTURE markerDepthTexture) {
  uint2 pixel = uint2(fragmentPosition.xy);
  if (pixel.x >= markerDepthTexture.get_width() ||
      pixel.y >= markerDepthTexture.get_height()) {
    return 0.0;
  }
#if VOLUME_SHADER_USES_AMPLIFICATION
  if (layerIndex >= markerDepthTexture.get_array_size()) {
    return 0.0;
  }
  return markerDepthTexture.read(pixel, layerIndex);
#else
  return markerDepthTexture.read(pixel);
#endif
}

#else
inline float markerDepthAtFragment(float4 fragmentPosition, uint layerIndex) {
  return 0.0;
}
#endif

// Clip z and w are affine along the ray. Prepare z - depth * w once,
// leaving only scalar interpolation and a sign-aware comparison per sample.
inline float4 prepareMarkerDepthTest(FragmentUniforms uniforms,
                                     float3 entryPoint,
                                     float3 exitPoint,
                                     float markerDepth) {
#if VOLUME_SHADER_USES_MARKER_TEXTURES
  if (markerDepth > 0.0) {
    float2 entry = (uniforms.textureToClip * float4(entryPoint, 1.0)).zw;
    float2 exit = (uniforms.textureToClip * float4(exitPoint, 1.0)).zw;
    float limit = markerDepth + 0.00001;
    return float4(entry.x - limit * entry.y, exit.x - limit * exit.y,
                  entry.y, exit.y);
  }
#endif
  return float4(1.0);
}

inline bool sampleReachedMarker(float4 depthTest, float sampleT) {
#if VOLUME_SHADER_USES_MARKER_TEXTURES
  float planeDistance = mix(depthTest.x, depthTest.y, sampleT);
  float clipW = mix(depthTest.z, depthTest.w, sampleT);
  if (clipW > 0.0) return planeDistance <= 0.0;
  if (clipW < 0.0) return planeDistance >= 0.0;
  // At the camera plane, preserve the original infinity/NaN comparison.
  return clipW == 0.0 && (signbit(clipW) ? planeDistance > 0.0 : planeDistance < 0.0);
#else
  return false;
#endif
}

// MARK: - Vertex Shader

/**
 Transforms mesh vertex positions and computes the ray exit point.

 - Parameters:
 - vertexId: Index of the current vertex.
 - amp_id: Amplification ID for multithreaded draws.
 - in: Buffer of input vertex positions.
 - uniformsArray: Double-buffered vertex uniforms containing view/projection matrices.
 - Returns: A `VertexToFragment` struct with transformed position and exit point.
 */
vertex VertexToFragment VOLUME_VERTEX_SHADER_NAME(
                                     uint vertexId [[vertex_id]] VOLUME_SHADER_AMP_PARAMETER,
                                     device const Vertex* in [[buffer(VertexBufferIndexMeshPositions)]],
                                     constant VertexUniformsArray& uniformsArray [[buffer(VertexBufferIndexUniforms)]]
                                     ) {
  VertexUniforms uniforms = uniformsArray.uniforms[VOLUME_SHADER_UNIFORM_INDEX];
  float4 pos4 = float4(in[vertexId].position, 1);

  VertexToFragment out;
  out.position = uniforms.modelViewProjectionMatrix * pos4;
  // Clip the volume, then map to [0,1] for exit point
  out.exitPoint = (uniforms.clipMatrix * pos4).xyz + 0.5;
  return out;
}


// MARK: - Transfer Function Fragment Shader

/**
 Performs volume raymarching with a 1D transfer function.

 - Parameters:
 - in: Interpolated vertex-to-fragment data (position + exit).
 - viewIndex: Eye index for the per-view uniforms and sampling phase.
 - markerDepth: Opaque geometry depth, or zero for the geometry-free specialization.
 - oversampling: Effective sample density, including the rasterization rate map.
 - volumeAtlas: 3D texture atlas containing volume bricks.
 - transferFunc: 1D transfer function texture.
 - uniformsArray: Double-buffered fragment uniforms for camera and rendering parameters.
 - levelData: Buffer containing LOD level metadata.
 - brickMeta: Buffer containing per-brick metadata.
 - hashBuffer: Atomic hash table buffer for missing-brick tracking.
 - Returns: The accumulated RGBA color after compositing along the ray.
 */
template<bool OpaqueGeometry>
inline VolumeFragmentOutput raycastTransferFunction(
                                VertexToFragment in, uint viewIndex,
                                float markerDepth, float oversampling,
                                texture3d<float> volumeAtlas,
                                texture3d<float> secondaryVolumeAtlas,
                                texture1d<half> transferFunc,
                                texture1d<half> transferFunc2,
                                texture1d<half> transferFunc3,
                                texture1d<half> transferFunc4,
                                device const FragmentUniformsArray& uniformsArray,
                                device const LevelData* levelData,
                                device const uint* brickMeta,
                                device atomic_uint* hashBuffer) {
  FragmentUniforms uniforms = uniformsArray.uniforms[viewIndex];
  constexpr sampler s(address::clamp_to_border, filter::linear);

  // Compute ray entry and exit in texture space
  float3 exitPoint  = in.exitPoint;
  float3 entryPoint = computeEntryPoint(uniforms.cameraPosInTextureSpace, exitPoint, uniforms);

  float3 direction = exitPoint - entryPoint;
  float rayLength = length(direction);

  // If ray is too short, return transparent
  if (rayLength < 1e-6) return volumeFragmentOutput(half4(0));

  float3 inverseDirection = inverseBrickRayDirection(direction);
  float4 markerDepthTest = prepareMarkerDepthTest(uniforms, entryPoint, exitPoint, markerDepth);

  // Compute distances for LOD selection
  float entryDepth = distanceFromCameraInNormalizedVolumeSpace(uniforms, entryPoint);
  float exitDepth  = distanceFromCameraInNormalizedVolumeSpace(uniforms, exitPoint);

  float3 voxelSpaceDirection = transformToPoolSpace(direction, oversampling);
  float  stepSize            = length(voxelSpaceDirection);
  float  samplePhase         = samplingPhase(uniforms, entryPoint, direction, viewIndex, 0.5);

  // Initialize ray marching
  float3 currentPos = entryPoint;
  float4 accColor   = float4(0);
  float4 colorAtOpaqueGeometry = float4(0);
  float interactionOpacity = 0;
  bool stoppedAtOpaqueGeometry = false;
  float3 interactionPosition = float3(0);
  float3 positionAtOpaqueGeometry = float3(0);
  float strongestContribution = 0;
  float t           = 0;
  uint  brickCount  = 0;

  // March until exit or full opacity
  while (t < 0.9999) {
    float currentDepth = mix(entryDepth, exitDepth, t);
    uint  iLOD         = computeLOD(currentDepth);

    BrickInformation brickResult = getBrick(
                                            currentPos, iLOD, direction, inverseDirection,
                                            uniforms.cubeBounds,
                                            brickMeta, levelData,
                                            hashBuffer, false
                                            );

#if STOP_ON_MISS == 1
    if (brickResult.substitute) {
      return visibleVolumeOutput(stoppedAtOpaqueGeometry, colorAtOpaqueGeometry, accColor,
                                 uniforms, strongestContribution > 0, interactionPosition,
                                 positionAtOpaqueGeometry);
    }
#endif

    float brickExitT = t + brickResult.rayExitDelta;
    if (!brickResult.empty) {
      // Number of samples within this brick
      float segmentLength = length(brickResult.poolBrickInfo.poolExitCoords
                                   - brickResult.poolBrickInfo.poolEntryCoords);
      int iSteps = int(ceil(segmentLength / stepSize));
      iSteps = min(int(2*BRICK_SIZE*oversampling),iSteps);
      float actualStepScale = segmentLength / max(float(iSteps) * stepSize, 1e-6);
      float ocFactor = float(1 << iLOD) * actualStepScale / oversampling;

      // Sample along the ray segment in this brick
      for (int i = 0; i < iSteps; ++i) {
        float sampleT = (float(i) + samplePhase) / float(iSteps);
        float3 sampleNormCoords = mix(
                                      currentPos,
                                      brickResult.normExitCoords,
                                      sampleT
                                      );
        if (OpaqueGeometry && !stoppedAtOpaqueGeometry && markerDepth > 0.0 &&
            sampleReachedMarker(markerDepthTest, mix(t, brickExitT, sampleT))) {
          colorAtOpaqueGeometry = accColor;
          positionAtOpaqueGeometry = interactionPosition;
          stoppedAtOpaqueGeometry = true;
        }
        float3 poolCoords = mix(
                                brickResult.poolBrickInfo.poolEntryCoords,
                                brickResult.poolBrickInfo.poolExitCoords,
                                sampleT
                                );

        float4 volumeValues = sampleVolumeComponents(
          volumeAtlas, secondaryVolumeAtlas, s, poolCoords
        );
        TransferFunctionSamples transferSamples = sampleTransferFunctions(
          volumeValues,
          uniforms.transferBias,
          s,
          transferFunc,
          transferFunc2,
          transferFunc3,
          transferFunc4
        );
        for (int channel = 0; channel < VOLUME_COMPONENT_COUNT; ++channel) {
          float4 current = transferSamples.values[channel];
          current.a = 1.0 - pow(1.0 - current.a, ocFactor);
          float contribution = (1.0 - interactionOpacity) * current.a;
          if (contribution > strongestContribution) {
            strongestContribution = contribution;
            interactionPosition = sampleNormCoords;
          }
          interactionOpacity += contribution;
          if (!stoppedAtOpaqueGeometry) {
            accColor = underFloat(current, accColor);
          }
        }

        // The visible color may stop at opaque geometry, while interaction depth
        // keeps searching the volume independently.
        if (interactionOpacity > 0.99) {
          return visibleVolumeOutput(stoppedAtOpaqueGeometry, colorAtOpaqueGeometry, accColor,
                                     uniforms, true, interactionPosition, positionAtOpaqueGeometry);
        }
      }
    }

    // Advance to the next brick
    currentPos = brickResult.normExitCoords;
    t = brickExitT;

    // Safety cap to prevent infinite loops
    brickCount++;
    if (brickCount == MAX_ITERATIONS) {
      return visibleVolumeOutput(stoppedAtOpaqueGeometry, colorAtOpaqueGeometry, accColor,
                                 uniforms, strongestContribution > 0, interactionPosition,
                                 positionAtOpaqueGeometry);
    }
  }

  return visibleVolumeOutput(stoppedAtOpaqueGeometry, colorAtOpaqueGeometry, accColor,
                             uniforms, strongestContribution > 0, interactionPosition,
                             positionAtOpaqueGeometry);
}

fragment VolumeFragmentOutput VOLUME_FRAGMENT_SHADER_TF_NAME(
                                VertexToFragment in [[stage_in]] VOLUME_SHADER_AMP_PARAMETER,
                                texture3d<float> volumeAtlas [[texture(TextureIndexVolumeAtlas)]],
                                texture3d<float> secondaryVolumeAtlas [[texture(TextureIndexVolumeAtlasSecondary)]],
                                texture1d<half> transferFunc [[texture(TextureIndexTransferFunction)]],
                                texture1d<half> transferFunc2 [[texture(TextureIndexTransferFunction2)]],
                                texture1d<half> transferFunc3 [[texture(TextureIndexTransferFunction3)]],
                                texture1d<half> transferFunc4 [[texture(TextureIndexTransferFunction4)]],
                                device const FragmentUniformsArray& uniformsArray [[buffer(FragmentBufferIndexUniforms)]],
                                device const LevelData* levelData [[buffer(FragmentBufferIndexLevelTable)]],
                                device const uint* brickMeta [[buffer(FragmentBufferIndexBrickMeta)]],
                                device atomic_uint* hashBuffer [[buffer(FragmentBufferIndexHashTable)]]
                                VOLUME_SHADER_RATE_MAP_PARAMETER
                                VOLUME_SHADER_MARKER_PARAMETER) {
  float markerDepth = markerDepthAtFragment(in.position,
                                            uint(VOLUME_SHADER_UNIFORM_INDEX)
                                            VOLUME_SHADER_MARKER_ARGUMENT);
  float oversampling = effectiveOversampling(uniformsArray.uniforms[VOLUME_SHADER_UNIFORM_INDEX].oversampling,
                                             in.position,
                                             uint(VOLUME_SHADER_UNIFORM_INDEX)
                                             VOLUME_SHADER_RATE_MAP_ARGUMENT);
  // Specialize per ray: most pixels have no geometry depth and need no state
  // for stopping visible color while independently continuing the picking ray.
  if (markerDepth > 0.0) {
    return raycastTransferFunction<true>(
      in, uint(VOLUME_SHADER_UNIFORM_INDEX), markerDepth, oversampling,
      volumeAtlas, secondaryVolumeAtlas, transferFunc, transferFunc2, transferFunc3, transferFunc4,
      uniformsArray, levelData, brickMeta, hashBuffer);
  }
  return raycastTransferFunction<false>(
    in, uint(VOLUME_SHADER_UNIFORM_INDEX), 0.0, oversampling,
    volumeAtlas, secondaryVolumeAtlas, transferFunc, transferFunc2, transferFunc3, transferFunc4,
    uniformsArray, levelData, brickMeta, hashBuffer);
}

/**
 Performs volume raymarching with a 1D transfer function an Lighting

 - Parameters:
 - in: Interpolated vertex-to-fragment data (position + exit).
 - amp_id: Amplification ID for multithreaded draws.
 - volumeAtlas: 3D texture atlas containing volume bricks.
 - transferFunc: 1D transfer function texture.
 - uniformsArray: Double-buffered fragment uniforms for camera and rendering parameters.
 - levelData: Buffer containing LOD level metadata.
 - brickMeta: Buffer containing per-brick metadata.
 - hashBuffer: Atomic hash table buffer for missing-brick tracking.
 - Returns: The accumulated RGBA color after compositing along the ray.
 */
fragment VolumeFragmentOutput VOLUME_FRAGMENT_SHADER_TF_LIGHTING_NAME(
                                VertexToFragment in [[stage_in]] VOLUME_SHADER_AMP_PARAMETER,
                                texture3d<float> volumeAtlas  [[texture(TextureIndexVolumeAtlas)]],
                                texture3d<float> secondaryVolumeAtlas [[texture(TextureIndexVolumeAtlasSecondary)]],
                                texture1d<half> transferFunc  [[texture(TextureIndexTransferFunction)]],
                                texture1d<half> transferFunc2 [[texture(TextureIndexTransferFunction2)]],
                                texture1d<half> transferFunc3 [[texture(TextureIndexTransferFunction3)]],
                                texture1d<half> transferFunc4 [[texture(TextureIndexTransferFunction4)]],
                                device const FragmentUniformsArray& uniformsArray [[buffer(FragmentBufferIndexUniforms)]],
                                device const LevelData* levelData                [[buffer(FragmentBufferIndexLevelTable)]],
                                device const uint* brickMeta                   [[buffer(FragmentBufferIndexBrickMeta)]],
                                device atomic_uint* hashBuffer                   [[buffer(FragmentBufferIndexHashTable)]]
                                VOLUME_SHADER_RATE_MAP_PARAMETER
                                VOLUME_SHADER_MARKER_PARAMETER
                                ) {
  FragmentUniforms uniforms = uniformsArray.uniforms[VOLUME_SHADER_UNIFORM_INDEX];
  float markerDepth = markerDepthAtFragment(in.position,
                                            uint(VOLUME_SHADER_UNIFORM_INDEX)
                                            VOLUME_SHADER_MARKER_ARGUMENT);
  float oversampling = effectiveOversampling(uniforms.oversampling,
                                             in.position,
                                             uint(VOLUME_SHADER_UNIFORM_INDEX)
                                             VOLUME_SHADER_RATE_MAP_ARGUMENT);
  constexpr sampler s(address::clamp_to_border, filter::linear);

  // Compute ray entry and exit in texture space
  float3 exitPoint  = in.exitPoint;
  float3 entryPoint = computeEntryPoint(uniforms.cameraPosInTextureSpace, exitPoint, uniforms);

  float3 direction = exitPoint - entryPoint;
  float rayLength = length(direction);

  // If ray is too short, return transparent
  if (rayLength < 1e-6) return volumeFragmentOutput(half4(0));

  float3 inverseDirection = inverseBrickRayDirection(direction);
  float4 markerDepthTest = prepareMarkerDepthTest(uniforms, entryPoint, exitPoint, markerDepth);

  // Compute distances for LOD selection
  float entryDepth = distanceFromCameraInNormalizedVolumeSpace(uniforms, entryPoint);
  float exitDepth  = distanceFromCameraInNormalizedVolumeSpace(uniforms, exitPoint);

  float3 voxelSpaceDirection = transformToPoolSpace(direction, oversampling);
  float  stepSize            = length(voxelSpaceDirection);
  float  samplePhase         = samplingPhase(uniforms, entryPoint, direction, uint(VOLUME_SHADER_UNIFORM_INDEX), 0.5);

  // Initialize ray marching
  float3 currentPos = entryPoint;
  float4 accColor   = float4(0);
  float4 colorAtOpaqueGeometry = float4(0);
  float interactionOpacity = 0;
  bool stoppedAtOpaqueGeometry = false;
  float3 interactionPosition = float3(0);
  float3 positionAtOpaqueGeometry = float3(0);
  float strongestContribution = 0;
  float t           = 0;
  uint  brickCount  = 0;

  // March until exit or full opacity
  while (t < 0.9999) {
    float currentDepth = mix(entryDepth, exitDepth, t);
    uint  iLOD         = computeLOD(currentDepth);

    BrickInformation brickResult = getBrick(
                                            currentPos, iLOD, direction, inverseDirection,
                                            uniforms.cubeBounds,
                                            brickMeta, levelData,
                                            hashBuffer, false
                                            );

#if STOP_ON_MISS == 1
    if (brickResult.substitute) {
      return visibleVolumeOutput(stoppedAtOpaqueGeometry, colorAtOpaqueGeometry, accColor,
                                 uniforms, strongestContribution > 0, interactionPosition,
                                 positionAtOpaqueGeometry);
    }
#endif

    float brickExitT = t + brickResult.rayExitDelta;
    if (!brickResult.empty) {
      // Number of samples within this brick
      float segmentLength = length(brickResult.poolBrickInfo.poolExitCoords
                                   - brickResult.poolBrickInfo.poolEntryCoords);
      int iSteps = int(ceil(segmentLength / stepSize));
      iSteps = min(int(2*BRICK_SIZE*oversampling),iSteps);
      float actualStepScale = segmentLength / max(float(iSteps) * stepSize, 1e-6);
      float ocFactor = float(1 << iLOD) * actualStepScale / oversampling;

      // Sample along the ray segment in this brick
      for (int i = 0; i < iSteps; ++i) {
        float sampleT = (float(i) + samplePhase) / float(iSteps);
        float3 sampleNormCoords = mix(
                                      currentPos,
                                      brickResult.normExitCoords,
                                      sampleT
                                      );
        if (!stoppedAtOpaqueGeometry && markerDepth > 0.0 &&
            sampleReachedMarker(markerDepthTest, mix(t, brickExitT, sampleT))) {
          colorAtOpaqueGeometry = accColor;
          positionAtOpaqueGeometry = interactionPosition;
          stoppedAtOpaqueGeometry = true;
        }
        float3 poolCoords = mix(
                                brickResult.poolBrickInfo.poolEntryCoords,
                                brickResult.poolBrickInfo.poolExitCoords,
                                sampleT
                                );
        float4 volumeValues = sampleVolumeComponents(
          volumeAtlas, secondaryVolumeAtlas, s, poolCoords
        );
        TransferFunctionSamples transferSamples = sampleTransferFunctions(
          volumeValues,
          uniforms.transferBias,
          s,
          transferFunc,
          transferFunc2,
          transferFunc3,
          transferFunc4
        );
        bool needsLighting = false;
        for (int channel = 0; channel < VOLUME_COMPONENT_COUNT; ++channel) {
          float correctedAlpha = 1.0 - pow(
            1.0 - transferSamples.values[channel].a,
            ocFactor
          );
          needsLighting = needsLighting || correctedAlpha > 0.01;
        }

        half3 posInView = half3(0.0);
        ComponentGradients componentGradients;
        if (needsLighting) {
          componentGradients = computeComponentGradients(
            poolCoords,
            1.0 / float3(POOL_SIZE),
            volumeAtlas,
            secondaryVolumeAtlas,
            s
          );
          posInView = half3((uniforms.modelView * float4((sampleNormCoords - 0.5),1)).xyz);
        }

        for (int channel = 0; channel < VOLUME_COMPONENT_COUNT; ++channel) {
          float4 current = transferSamples.values[channel];
          current.a = 1.0 - pow(1.0 - current.a, ocFactor);
          float contribution = (1.0 - interactionOpacity) * current.a;
          if (contribution > strongestContribution) {
            strongestContribution = contribution;
            interactionPosition = sampleNormCoords;
          }
          interactionOpacity += contribution;

          if (current.a > 0.01) {
            float3 normal = componentNormal(
              componentGradients,
              channel,
              float3(1, 1, 1)
            );
            half3 normalInView = half3(safeNormalize(
              (uniforms.modelViewIT * float4(normal, 0)).xyz
            ));
            current.rgb = float3(lighting(
                                            posInView,
                                            normalInView,
                                            half3(current.rgb),
                                            half3(uniforms.lightDirection.xyz),
                                            half3(uniforms.ambientLightColor.xyz),
                                            half3(uniforms.diffuseLightColor.xyz),
                                            half3(uniforms.specularLightColor.xyz)
                                            ));
          }

          if (!stoppedAtOpaqueGeometry) {
            accColor = underFloat(current, accColor);
          }
        }

        // The visible color may stop at opaque geometry, while interaction depth
        // keeps searching the volume independently.
        if (interactionOpacity > 0.99) {
          return visibleVolumeOutput(stoppedAtOpaqueGeometry, colorAtOpaqueGeometry, accColor,
                                     uniforms, true, interactionPosition, positionAtOpaqueGeometry);
        }
      }
    }

    // Advance to the next brick
    currentPos = brickResult.normExitCoords;
    t = brickExitT;

    // Safety cap to prevent infinite loops
    brickCount++;
    if (brickCount == MAX_ITERATIONS) {
      return visibleVolumeOutput(stoppedAtOpaqueGeometry, colorAtOpaqueGeometry, accColor,
                                 uniforms, strongestContribution > 0, interactionPosition,
                                 positionAtOpaqueGeometry);
    }
  }

  return visibleVolumeOutput(stoppedAtOpaqueGeometry, colorAtOpaqueGeometry, accColor,
                             uniforms, strongestContribution > 0, interactionPosition,
                             positionAtOpaqueGeometry);
}

// MARK: - Isosurface Fragment Shader

/**
 Performs volume raymarching for isosurface rendering.

 - Parameters: Similar to `fragmentShaderTF`, but uses a fixed isoValue threshold.
 - Returns: The shaded color at the isosurface intersection, or transparent if none found.
 */
fragment VolumeFragmentOutput VOLUME_FRAGMENT_SHADER_ISO_NAME(
                                 VertexToFragment in [[stage_in]] VOLUME_SHADER_AMP_PARAMETER,
                                 texture3d<float> volumeAtlas                     [[texture(TextureIndexVolumeAtlas)]],
                                 texture3d<float> secondaryVolumeAtlas            [[texture(TextureIndexVolumeAtlasSecondary)]],
                                 device const FragmentUniformsArray& uniformsArray [[buffer(FragmentBufferIndexUniforms)]],
                                 device const LevelData* levelData                 [[buffer(FragmentBufferIndexLevelTable)]],
                                 device const uint* brickMeta                    [[buffer(FragmentBufferIndexBrickMeta)]],
                                 device atomic_uint* hashBuffer                    [[buffer(FragmentBufferIndexHashTable)]]
                                 VOLUME_SHADER_RATE_MAP_PARAMETER
                                 VOLUME_SHADER_MARKER_PARAMETER
                                 ) {
  FragmentUniforms uniforms = uniformsArray.uniforms[VOLUME_SHADER_UNIFORM_INDEX];
  float markerDepth = markerDepthAtFragment(in.position,
                                            uint(VOLUME_SHADER_UNIFORM_INDEX)
                                            VOLUME_SHADER_MARKER_ARGUMENT);
  float oversampling = effectiveOversampling(uniforms.oversampling,
                                             in.position,
                                             uint(VOLUME_SHADER_UNIFORM_INDEX)
                                             VOLUME_SHADER_RATE_MAP_ARGUMENT);
  constexpr sampler s(address::clamp_to_border, filter::linear);

  float3 exitPoint  = in.exitPoint;
  float3 entryPoint = computeEntryPoint(uniforms.cameraPosInTextureSpace, exitPoint, uniforms);

  float3 direction = exitPoint - entryPoint;
  float rayLength = length(direction);

  if (rayLength < 1e-6) return volumeFragmentOutput(half4(0));

  float3 inverseDirection = inverseBrickRayDirection(direction);
  float4 markerDepthTest = prepareMarkerDepthTest(uniforms, entryPoint, exitPoint, markerDepth);

  float entryDepth = distanceFromCameraInNormalizedVolumeSpace(uniforms, entryPoint);
  float exitDepth  = distanceFromCameraInNormalizedVolumeSpace(uniforms, exitPoint);

  float3 voxelSpaceDirection = transformToPoolSpace(direction, oversampling);
  float  stepSize            = length(voxelSpaceDirection);
  float  samplePhase         = samplingPhase(uniforms, entryPoint, direction, uint(VOLUME_SHADER_UNIFORM_INDEX), 0.5);

  float3 currentPos = entryPoint;
  bool stoppedAtOpaqueGeometry = false;
  float t           = 0;
  uint  brickCount  = 0;

  while (t < 0.9999) {
    float currentDepth = mix(entryDepth, exitDepth, t);
    uint  iLOD         = computeLOD(currentDepth);

    BrickInformation brickResult = getBrick(
                                            currentPos, iLOD, direction, inverseDirection,
                                            uniforms.cubeBounds,
                                            brickMeta, levelData,
                                            hashBuffer, false
                                            );
#if STOP_ON_MISS == 1
    if (brickResult.substitute) return volumeFragmentOutput(half4(0));
#endif
    
    float brickExitT = t + brickResult.rayExitDelta;
    if (!brickResult.empty) {
      int iSteps = int(ceil(
                            length(brickResult.poolBrickInfo.poolExitCoords
                                   - brickResult.poolBrickInfo.poolEntryCoords) / stepSize
                            ));
      iSteps = min(int(2*BRICK_SIZE*oversampling),iSteps);
      for (int i = 0; i < iSteps; ++i) {
        float sampleT = (float(i) + samplePhase) / float(iSteps);
        float3 sampleNormCoords = mix(
                                      currentPos,
                                      brickResult.normExitCoords,
                                      sampleT
                                      );
        if (!stoppedAtOpaqueGeometry && markerDepth > 0.0 &&
            sampleReachedMarker(markerDepthTest, mix(t, brickExitT, sampleT))) {
          stoppedAtOpaqueGeometry = true;
        }
        float3 poolCoords = mix(
                                brickResult.poolBrickInfo.poolEntryCoords,
                                brickResult.poolBrickInfo.poolExitCoords,
                                sampleT
                                );
        float value = sampleVolumeScalar(volumeAtlas, secondaryVolumeAtlas, s, poolCoords);
        if (value >= uniforms.isoValue) {
          poolCoords = refineIsosurface(
                                        voxelSpaceDirection,
                                        poolCoords,
                                        uniforms.isoValue,
                                        volumeAtlas,
                                        secondaryVolumeAtlas,
                                        s
                                        );
          float3 normal = computeNormal(
                                        poolCoords, POOL_SIZE,
                                        float3(1,1,1),
                                        volumeAtlas,
                                        secondaryVolumeAtlas,
                                        s
                                        );
          half3 posInView    = half3((uniforms.modelView * float4((sampleNormCoords - 0.5),1)).xyz);
          half3 normalInView = half3(normalize((uniforms.modelViewIT * float4(normal,0)).xyz));
          half3 color = lighting(
                                 posInView,
                                 normalInView,
                                 half3(0.5,0.5,0.5),
                                 half3(uniforms.lightDirection.xyz),
                                 half3(uniforms.ambientLightColor.xyz),
                                 half3(uniforms.diffuseLightColor.xyz),
                                 half3(uniforms.specularLightColor.xyz)
                                 );
          return volumeFragmentOutput(
            stoppedAtOpaqueGeometry ? half4(0) : half4(color, 1),
            uniforms,
            sampleNormCoords
          );
        }
      }
    }

    currentPos = brickResult.normExitCoords;
    t = brickExitT;

    // Safety cap to prevent infinite loops
    brickCount++;
    if (brickCount == MAX_ITERATIONS) return volumeFragmentOutput(half4(0));
  }

  return volumeFragmentOutput(half4(0));
}

// MARK: - Brick Visualization Fragment Shader

/**
 Visualizes brick occupancy by coloring empty vs. loaded bricks along the ray.

 - Empty bricks are green, resident bricks red, and missing bricks blue.
 - Empty runs are not coalesced: every brick must contribute the same weight.
 */
fragment VolumeFragmentOutput VOLUME_FRAGMENT_SHADER_BRICK_VIS_NAME(
                                      VertexToFragment in [[stage_in]] VOLUME_SHADER_AMP_PARAMETER,
                                      device const FragmentUniformsArray& uniformsArray [[buffer(FragmentBufferIndexUniforms)]],
                                      device const LevelData* levelData                 [[buffer(FragmentBufferIndexLevelTable)]],
                                      device const uint* brickMeta                    [[buffer(FragmentBufferIndexBrickMeta)]],
                                      device atomic_uint* hashBuffer                    [[buffer(FragmentBufferIndexHashTable)]]
                                      ) {
  FragmentUniforms uniforms = uniformsArray.uniforms[VOLUME_SHADER_UNIFORM_INDEX];

  float3 exitPoint  = in.exitPoint;
  float3 entryPoint = computeEntryPoint(uniforms.cameraPosInTextureSpace, exitPoint, uniforms);

  float3 direction = exitPoint - entryPoint;
  float rayLength = length(direction);

  if (rayLength < 1e-6) return volumeFragmentOutput(half4(0));

  float3 inverseDirection = inverseBrickRayDirection(direction);
  float entryDepth = distanceFromCameraInNormalizedVolumeSpace(uniforms, entryPoint);
  float exitDepth  = distanceFromCameraInNormalizedVolumeSpace(uniforms, exitPoint);

  float3 currentPos = entryPoint;
  half4 accColor    = half4(0);
  float t           = 0;
  uint  brickCount  = 0;

  while (t < 0.9999) {
    float currentDepth = mix(entryDepth, exitDepth, t);
    uint  iLOD         = computeLOD(currentDepth);

    BrickInformation brickResult = getBrick(
                                            currentPos, iLOD, direction, inverseDirection,
                                            uniforms.cubeBounds,
                                            brickMeta, levelData,
                                            hashBuffer, true, false
                                            );

    if (brickResult.substitute) {
      accColor += half4(0, 0, 0.1, 0.1);
    } else if (brickResult.empty) {
      accColor += half4(0, 0.1, 0, 0.1);
    } else {
      accColor += half4(0.1, 0, 0, 0.1);
    }

    currentPos = brickResult.normExitCoords;
    t += brickResult.rayExitDelta;

    // Safety cap to prevent infinite loops
    brickCount++;
    if (brickCount == MAX_ITERATIONS) return volumeFragmentOutput(accColor);
  }

  return volumeFragmentOutput(accColor);
}

/*
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of Duisburg-
 Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of this
 software and associated documentation files (the "Software"), to deal in the Software
 without restriction, including without limitation the rights to use, copy, modify,
 merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 permit persons to whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included in all copies
 or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
 CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR
 THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
