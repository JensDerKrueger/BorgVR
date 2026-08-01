//
//  Shaders.metal
//
//  File for Metal kernel and shader functions
//

#include <metal_stdlib>

// The app compiles this file at runtime with makeLibrary(source:options:).
// Keep the required shared shader types and helpers inline so iOS does not have to resolve project-local includes.

using namespace metal;

enum BrickIDFlags {
  BI_MISSING = 0,
  BI_CHILD_EMPTY = 1,
  BI_EMPTY = 2,
  BI_FLAG_COUNT = 3
};

enum VertexBufferIndex {
  VertexBufferIndexMeshPositions = 0,
  VertexBufferIndexUniforms = 1
};

enum FragmentBufferIndex {
  FragmentBufferIndexUniforms = 0,
  FragmentBufferIndexLevelTable = 1,
  FragmentBufferIndexBrickMeta = 2,
  FragmentBufferIndexHashTable = 3
};

enum TextureIndex {
  TextureIndexVolumeAtlas = 0,
  TextureIndexTransferFunction = 1
};

struct FragmentUniforms {
  float isoValue;
  float oversampling;
  float transferBias;
  float3 cameraPosInTextureSpace;
  float3 cameraPosInTextureSpaceVoxelScaled;
  float3 cubeBounds[2];
  float4x4 modelView;
  float4x4 modelViewIT;
};

struct FragmentUniformsArray {
  FragmentUniforms uniforms[2];
};

struct VertexUniforms {
  float4x4 modelViewProjectionMatrix;
  float4x4 clipMatrix;
};

struct VertexUniformsArray {
  VertexUniforms uniforms[2];
};

struct Vertex {
  float3 position;
};

struct LevelData {
  uint bricksX;
  uint bricksXTimesBricksY;
  uint prevBricks;
  float3 fractionalBrickLayout;
};

uint simpleHash(uint value) {
  return value * 2654435761u;
}

void reportMissingBrick(uint brickIndex, device atomic_uint* atomicBuffer) {
  uint hashIndex = simpleHash(brickIndex) % HASHTABLE_SIZE;
  for (uint i = 0; i < MAX_PROBING_ATTEMPTS; ++i) {
    uint slot = (hashIndex + i) % HASHTABLE_SIZE;
    uint expected = 0xFFFFFFFFu;
    if (atomic_compare_exchange_weak_explicit(&atomicBuffer[slot],
                                              &expected,
                                              brickIndex,
                                              memory_order_relaxed,
                                              memory_order_relaxed)) {
      break;
    } else if (expected == brickIndex) {
      break;
    }
  }
}

uint getBrickIndex(uint4 brickCoords, device const LevelData *levelArray) {
  LevelData level = levelArray[brickCoords.w];
  return level.prevBricks +
         brickCoords.x +
         brickCoords.y * level.bricksX +
         brickCoords.z * level.bricksXTimesBricksY;
}

uint4 computeBrickCoords(float3 normEntryCoords, device const LevelData *levelArray, uint LOD) {
  LevelData level = levelArray[LOD];
  return uint4(uint3(normEntryCoords * level.fractionalBrickLayout), LOD);
}

struct BrickCorners {
  float3 values[2];
};

BrickCorners getBrickCorners(uint4 brickCoords, device const LevelData *levelArray) {
  BrickCorners c;
  c.values[0] = float3(brickCoords.xyz) / levelArray[brickCoords.w].fractionalBrickLayout;
  c.values[1] = float3(brickCoords.xyz + 1) / levelArray[brickCoords.w].fractionalBrickLayout;
  return c;
}

float3 brickExit(float3 pointInBrick, float3 dir, float3 cubeBounds[2], BrickCorners corners) {
  float3 div = 1.0 / dir;
  uint3 side = uint3(step(0.0, div));
  float3 tIntersect;

  tIntersect.x = (corners.values[side.x].x - pointInBrick.x) * div.x;
  tIntersect.y = (corners.values[side.y].y - pointInBrick.y) * div.y;
  tIntersect.z = (corners.values[side.z].z - pointInBrick.z) * div.z;

  tIntersect.x = min(tIntersect.x, (cubeBounds[side.x].x - pointInBrick.x) * div.x);
  tIntersect.y = min(tIntersect.y, (cubeBounds[side.y].y - pointInBrick.y) * div.y);
  tIntersect.z = min(tIntersect.z, (cubeBounds[side.z].z - pointInBrick.z) * div.z);

  return pointInBrick + min(min(tIntersect.x, tIntersect.y), tIntersect.z) * dir;
}

uint3 infoToCoords(uint brickInfo) {
  uint brickID = brickInfo - BI_FLAG_COUNT;
  uint3 vBrickCoords;
  vBrickCoords.x = brickID % POOL_CAPACITY.x;
  vBrickCoords.y = (brickID / POOL_CAPACITY.x) % POOL_CAPACITY.y;
  vBrickCoords.z = brickID / (POOL_CAPACITY.x * POOL_CAPACITY.y);
  return vBrickCoords;
}

BrickCorners brickPoolCoords(uint brickInfo) {
  uint3 poolVoxelPos = infoToCoords(brickInfo) * BRICK_SIZE;
  BrickCorners c;
  c.values[0] = (float3(poolVoxelPos) / POOL_SIZE) + OVERLAP_STEP;
  c.values[1] = (float3(poolVoxelPos + BRICK_SIZE) / POOL_SIZE) - OVERLAP_STEP;
  return c;
}

struct PoolBrickInformation {
  float3 poolEntryCoords;
  float3 poolExitCoords;
  float3 normToPoolScale;
  float3 normToPoolTrans;
};

PoolBrickInformation normCoordsToPoolCoords(float3 normEntryCoords,
                                            float3 normExitCoords,
                                            BrickCorners corners,
                                            uint brickInfo) {
  PoolBrickInformation info;
  BrickCorners poolCorners = brickPoolCoords(brickInfo);
  info.normToPoolScale = (poolCorners.values[1] - poolCorners.values[0]) / (corners.values[1] - corners.values[0]);
  info.normToPoolTrans = poolCorners.values[0] - corners.values[0] * info.normToPoolScale;
  info.poolEntryCoords = normEntryCoords * info.normToPoolScale + info.normToPoolTrans;
  info.poolExitCoords = normExitCoords * info.normToPoolScale + info.normToPoolTrans;
  return info;
}

struct BrickInformation {
  uint LOD;
  uint brickIndex;
  bool empty;
  bool substitute;
  float3 normExitCoords;
  PoolBrickInformation poolBrickInfo;
};

BrickInformation getBrick(float3 normEntryCoords,
                          uint iLOD,
                          float3 direction,
                          float3 cubeBounds[2],
                          device const uint *brickMeta,
                          device const LevelData *levelArray,
                          device atomic_uint* hashBuffer,
                          bool dontRequest) {
  BrickInformation info;
  info.LOD = iLOD;

  normEntryCoords = clamp(normEntryCoords, float3(0), float3(1));

  uint4 brickCoords = computeBrickCoords(normEntryCoords, levelArray, info.LOD);
  uint brickIndex = getBrickIndex(brickCoords, levelArray);
  uint brickInfo = brickMeta[brickIndex];

  info.brickIndex = brickIndex;
  info.substitute = brickInfo == BI_MISSING;

  if (!dontRequest && brickInfo == BI_MISSING) {
    reportMissingBrick(brickIndex, hashBuffer);

    uint startLOD = info.LOD;
    int lastBrickIndex = brickIndex;
    do {
      lastBrickIndex = brickIndex;
      info.LOD++;
      brickCoords = computeBrickCoords(normEntryCoords, levelArray, info.LOD);
      brickIndex = getBrickIndex(brickCoords, levelArray);
      brickInfo = brickMeta[brickIndex];
    } while (brickInfo == BI_MISSING);

#if REQUEST_LOWRES_LOD == 1
    if (startLOD < info.LOD) {
      reportMissingBrick(lastBrickIndex, hashBuffer);
    }
#endif
  }

  info.empty = brickInfo <= BI_EMPTY;
  if (info.empty) {
    for (uint lowResLOD = info.LOD + 1; lowResLOD < LEVEL_COUNT; ++lowResLOD) {
      uint4 lowResBrickCoords = computeBrickCoords(normEntryCoords, levelArray, lowResLOD);
      uint lowResBrickIndex = getBrickIndex(lowResBrickCoords, levelArray);
      uint lowResBrickInfo = brickMeta[lowResBrickIndex];
      if (lowResBrickInfo == BI_CHILD_EMPTY) {
        brickCoords = lowResBrickCoords;
        brickInfo = lowResBrickInfo;
        info.LOD = lowResLOD;
      } else {
        break;
      }
    }
  }

  BrickCorners corners = getBrickCorners(brickCoords, levelArray);
  info.normExitCoords = brickExit(normEntryCoords, direction, cubeBounds, corners);
  if (info.empty) return info;

  info.poolBrickInfo = normCoordsToPoolCoords(normEntryCoords,
                                              info.normExitCoords,
                                              corners,
                                              brickInfo);
  return info;
}

uint computeLOD(float dist) {
  float lod = log2(max(LOD_FACTOR * dist / LEVEL_ZERO_WORLD_SPACE_ERROR, 1.0));
  return min(uint(LEVEL_COUNT - 1), uint(lod));
}

float3 getSampleDelta() {
  return 1.0 / POOL_SIZE;
}

float3 transformToPoolSpace(float3 direction, float sampleRateModifier) {
  direction *= VOLUME_SIZE;
  direction = normalize(direction);
  direction /= POOL_SIZE;
  return direction / (2.0 * sampleRateModifier);
}

half4 under(half4 current, half4 last) {
  last.rgb = clamp(last.rgb + (1.0 - last.a) * current.a * current.rgb, 0.0, 1.0);
  last.a = min(1.0, last.a + (1.0 - last.a) * current.a);
  return last;
}

float4 underFloat(float4 current, float4 last) {
  last.rgb = clamp(last.rgb + (1.0 - last.a) * current.a * current.rgb, 0.0, 1.0);
  last.a = min(1.0, last.a + (1.0 - last.a) * current.a);
  return last;
}

inline void swap(thread float &a, thread float &b) {
  float temp = a;
  a = b;
  b = temp;
}

inline float3 computeEntryPoint(float3 P, float3 Q, FragmentUniforms params) {
  const float3 minB = params.cubeBounds[0];
  const float3 maxB = params.cubeBounds[1];

  if ((P.x >= minB.x && P.x <= maxB.x) &&
      (P.y >= minB.y && P.y <= maxB.y) &&
      (P.z >= minB.z && P.z <= maxB.z)) {
    return P;
  }

  float3 d = Q - P;
  const float eps = 1e-6;

  float tx1 = (minB.x - P.x) / (abs(d.x) > eps ? d.x : copysign(eps, d.x));
  float tx2 = (maxB.x - P.x) / (abs(d.x) > eps ? d.x : copysign(eps, d.x));
  if (d.x < 0.0) swap(tx1, tx2);

  float ty1 = (minB.y - P.y) / (abs(d.y) > eps ? d.y : copysign(eps, d.y));
  float ty2 = (maxB.y - P.y) / (abs(d.y) > eps ? d.y : copysign(eps, d.y));
  if (d.y < 0.0) swap(ty1, ty2);

  float tz1 = (minB.z - P.z) / (abs(d.z) > eps ? d.z : copysign(eps, d.z));
  float tz2 = (maxB.z - P.z) / (abs(d.z) > eps ? d.z : copysign(eps, d.z));
  if (d.z < 0.0) swap(tz1, tz2);

  float tEntry = max(tx1, max(ty1, tz1));
  float tExit = min(tx2, min(ty2, tz2));

  if (tEntry <= tExit && tExit >= 0.0) {
    return P + tEntry * d;
  }

  return P;
}

inline half3 lighting(half3 position, half3 normal, half3 color) {
  const half3 ambientLight = half3(0.1, 0.1, 0.1);
  const half3 diffuseLight = half3(0.5, 0.5, 0.5);
  const half3 specularLight = half3(0.8, 0.8, 0.8);
  const half shininess = 8.0;

  half3 viewDir = normalize(-position);
  half3 lightDir = viewDir;
  half3 reflection = reflect(-lightDir, normal);

  half diffuse = fmax(abs(dot(normal, lightDir)), 0);
  half specular = pow(fmax(dot(viewDir, reflection), 0), shininess);

  half3 shaded =
  color * ambientLight +
  color * diffuseLight * diffuse +
  specularLight * specular;
  return clamp(shaded, 0.0, 1.0);
}

float3 computeGradient(float3 vCenter,
                       float3 sampleDelta,
                       texture3d<half, access::sample> volume [[texture(0)]],
                       sampler s) {
  float fVolumValXp = volume.sample(s, vCenter + float3(+sampleDelta.x, 0, 0)).r;
  float fVolumValXm = volume.sample(s, vCenter + float3(-sampleDelta.x, 0, 0)).r;
  float fVolumValYp = volume.sample(s, vCenter + float3(0, +sampleDelta.y, 0)).r;
  float fVolumValYm = volume.sample(s, vCenter + float3(0, -sampleDelta.y, 0)).r;
  float fVolumValZp = volume.sample(s, vCenter + float3(0, 0, +sampleDelta.z)).r;
  float fVolumValZm = volume.sample(s, vCenter + float3(0, 0, -sampleDelta.z)).r;

  return float3(fVolumValXp - fVolumValXm,
                fVolumValYp - fVolumValYm,
                fVolumValZp - fVolumValZm) / 2.0;
}

inline float3 safeNormalize(float3 v) {
  float len = length(v);
  return len > 0.0 ? v / len : float3(0);
}

float3 computeNormal(float3 vCenter,
                     float3 volSize,
                     float3 DomainScale,
                     texture3d<half, access::sample> volume [[texture(0)]],
                     sampler s) {
  float3 vGradient = computeGradient(vCenter, 1 / volSize, volume, s);
  float3 vNormal = vGradient * DomainScale;
  return safeNormalize(vNormal);
}

inline float3 refineIsosurface(float3 vRayDir,
                               float3 vCurrentPos,
                               float fIsoval,
                               texture3d<half, access::sample> volume [[texture(0)]],
                               sampler s) {
  vRayDir /= 2.0;
  vCurrentPos -= vRayDir;
  for (int i = 0; i < 5; i++) {
    vRayDir /= 2.0;
    float voxel = volume.sample(s, vCurrentPos).x;
    if (voxel >= fIsoval) {
      vCurrentPos -= vRayDir;
    } else {
      vCurrentPos += vRayDir;
    }
    if (abs(voxel - fIsoval) < 0.001) break;
  }
  return vCurrentPos;
}

typedef struct {
  /// Clip-space position of the vertex.
  simd_float4 position [[position]];
  /// Exit point of the ray in texture coordinate space (0–1 range).
  simd_float3 exitPoint;
} VertexToFragment;

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
vertex VertexToFragment macOSVertexShader(
                                     uint vertexId [[vertex_id]],
                                     device const Vertex* in [[buffer(VertexBufferIndexMeshPositions)]],
                                     constant VertexUniformsArray& uniformsArray [[buffer(VertexBufferIndexUniforms)]]
                                     ) {
  VertexUniforms uniforms = uniformsArray.uniforms[0];
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
 - amp_id: Amplification ID for multithreaded draws.
 - volumeAtlas: 3D texture atlas containing volume bricks.
 - transferFunc: 1D transfer function texture.
 - uniformsArray: Double-buffered fragment uniforms for camera and rendering parameters.
 - levelData: Buffer containing LOD level metadata.
 - brickMeta: Buffer containing per-brick metadata.
 - hashBuffer: Atomic hash table buffer for missing-brick tracking.
 - Returns: The accumulated RGBA color after compositing along the ray.
 */
fragment half4 macOSFragmentShaderTF(
                                VertexToFragment in [[stage_in]],
                                texture3d<half> volumeAtlas   [[texture(TextureIndexVolumeAtlas)]],
                                texture1d<half> transferFunc  [[texture(TextureIndexTransferFunction)]],
                                device const FragmentUniformsArray& uniformsArray [[buffer(FragmentBufferIndexUniforms)]],
                                device const LevelData* levelData                [[buffer(FragmentBufferIndexLevelTable)]],
                                device const uint* brickMeta                     [[buffer(FragmentBufferIndexBrickMeta)]],
                                device atomic_uint* hashBuffer                   [[buffer(FragmentBufferIndexHashTable)]]
                                ) {
  FragmentUniforms uniforms = uniformsArray.uniforms[0];
  constexpr sampler s(address::clamp_to_border, filter::linear);
  float3 stepEpsilon = 0.125 / POOL_SIZE;

  // Compute ray entry and exit in texture space
  float3 exitPoint  = in.exitPoint;
  float3 entryPoint = computeEntryPoint(uniforms.cameraPosInTextureSpace, exitPoint, uniforms);

  // Adjust entry point to avoid self-intersection
  float3 direction = normalize(exitPoint - entryPoint);
  entryPoint += direction * stepEpsilon;
  direction = exitPoint - entryPoint;
  float rayLength = length(direction);

  // If ray is too short, return transparent
  if (rayLength < length(stepEpsilon)) return half4(0);

  // Compute distances for LOD selection
  float entryDepth = length(uniforms.cameraPosInTextureSpaceVoxelScaled - entryPoint);
  float exitDepth  = length(uniforms.cameraPosInTextureSpaceVoxelScaled - exitPoint);

  float3 voxelSpaceDirection = transformToPoolSpace(direction, uniforms.oversampling);
  float  stepSize            = length(voxelSpaceDirection);

  // Initialize ray marching
  float3 currentPos = entryPoint;
  float4 accColor   = float4(0);
  float t           = 0;
  uint  brickCount  = 0;

  // March until exit or full opacity
  while (t < 0.9999) {
    float currentDepth = mix(entryDepth, exitDepth, t);
    uint  iLOD         = computeLOD(currentDepth);

    BrickInformation brickResult = getBrick(
                                            currentPos, iLOD, direction,
                                            uniforms.cubeBounds,
                                            brickMeta, levelData,
                                            hashBuffer, false
                                            );

#if STOP_ON_MISS == 1
    if (brickResult.substitute) return half4(accColor);
#endif

    if (!brickResult.empty) {
      // Number of samples within this brick
      float segmentLength = length(brickResult.poolBrickInfo.poolExitCoords
                                   - brickResult.poolBrickInfo.poolEntryCoords);
      int iSteps = int(ceil(segmentLength / stepSize));
      iSteps = min(int(2*BRICK_SIZE*uniforms.oversampling),iSteps);
      float actualStepScale = segmentLength / max(float(iSteps) * stepSize, 1e-6);
      float ocFactor = float(1 << iLOD) * actualStepScale / uniforms.oversampling;

      // Sample along the ray segment in this brick
      for (int i = 0; i < iSteps; ++i) {
        float sampleT = (float(i) + 0.5) / float(iSteps);
        float3 poolCoords = mix(
                                brickResult.poolBrickInfo.poolEntryCoords,
                                brickResult.poolBrickInfo.poolExitCoords,
                                sampleT
                                );

        float volumeValue = volumeAtlas.sample(s, poolCoords).r;
        float4 current = float4(transferFunc.sample(s, volumeValue * uniforms.transferBias));
        current.a = 1.0 - pow(1.0 - current.a, ocFactor);
        accColor = underFloat(current, accColor);

        // Early ray termination on high opacity
        if (accColor.a > 0.99) return half4(accColor);
      }
    }

    // Advance to the next brick
    currentPos = brickResult.normExitCoords + (stepEpsilon * direction / rayLength);
    t = length(entryPoint - currentPos) / rayLength;

    // Safety cap to prevent infinite loops
    brickCount++;
    if (brickCount == MAX_ITERATIONS) return half4(accColor);
  }

  return half4(accColor);
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
fragment half4 macOSFragmentShaderTFLighting(
                                VertexToFragment in [[stage_in]],
                                texture3d<half> volumeAtlas   [[texture(TextureIndexVolumeAtlas)]],
                                texture1d<half> transferFunc  [[texture(TextureIndexTransferFunction)]],
                                device const FragmentUniformsArray& uniformsArray [[buffer(FragmentBufferIndexUniforms)]],
                                device const LevelData* levelData                [[buffer(FragmentBufferIndexLevelTable)]],
                                device const uint* brickMeta                   [[buffer(FragmentBufferIndexBrickMeta)]],
                                device atomic_uint* hashBuffer                   [[buffer(FragmentBufferIndexHashTable)]]
                                ) {
  FragmentUniforms uniforms = uniformsArray.uniforms[0];
  constexpr sampler s(address::clamp_to_border, filter::linear);
  float3 stepEpsilon = 0.125 / POOL_SIZE;

  // Compute ray entry and exit in texture space
  float3 exitPoint  = in.exitPoint;
  float3 entryPoint = computeEntryPoint(uniforms.cameraPosInTextureSpace, exitPoint, uniforms);

  // Adjust entry point to avoid self-intersection
  float3 direction = normalize(exitPoint - entryPoint);
  entryPoint += direction * stepEpsilon;
  direction = exitPoint - entryPoint;
  float rayLength = length(direction);

  // If ray is too short, return transparent
  if (rayLength < length(stepEpsilon)) return half4(0);

  // Compute distances for LOD selection
  float entryDepth = length(uniforms.cameraPosInTextureSpaceVoxelScaled - entryPoint);
  float exitDepth  = length(uniforms.cameraPosInTextureSpaceVoxelScaled - exitPoint);

  float3 voxelSpaceDirection = transformToPoolSpace(direction, uniforms.oversampling);
  float  stepSize            = length(voxelSpaceDirection);

  // Initialize ray marching
  float3 currentPos = entryPoint;
  float4 accColor   = float4(0);
  float t           = 0;
  uint  brickCount  = 0;

  // March until exit or full opacity
  while (t < 0.9999) {
    float currentDepth = mix(entryDepth, exitDepth, t);
    uint  iLOD         = computeLOD(currentDepth);

    BrickInformation brickResult = getBrick(
                                            currentPos, iLOD, direction,
                                            uniforms.cubeBounds,
                                            brickMeta, levelData,
                                            hashBuffer, false
                                            );

#if STOP_ON_MISS == 1
    if (brickResult.substitute) return half4(accColor);
#endif

    if (!brickResult.empty) {
      // Number of samples within this brick
      float segmentLength = length(brickResult.poolBrickInfo.poolExitCoords
                                   - brickResult.poolBrickInfo.poolEntryCoords);
      int iSteps = int(ceil(segmentLength / stepSize));
      iSteps = min(int(2*BRICK_SIZE*uniforms.oversampling),iSteps);
      float actualStepScale = segmentLength / max(float(iSteps) * stepSize, 1e-6);
      float ocFactor = float(1 << iLOD) * actualStepScale / uniforms.oversampling;

      // Sample along the ray segment in this brick
      for (int i = 0; i < iSteps; ++i) {
        float sampleT = (float(i) + 0.5) / float(iSteps);
        float3 poolCoords = mix(
                                brickResult.poolBrickInfo.poolEntryCoords,
                                brickResult.poolBrickInfo.poolExitCoords,
                                sampleT
                                );
        float volumeValue = volumeAtlas.sample(s, poolCoords).r;
        float4 current = float4(transferFunc.sample(s, volumeValue * uniforms.transferBias));
        // Opacity correction
        current.a = 1.0 - pow(1.0 - current.a, ocFactor);

        if (current.a > 0.01) {
          float3 normal = computeNormal(
                                        poolCoords, POOL_SIZE,
                                        float3(1,1,1),
                                        volumeAtlas,
                                        s
                                        );

          half3 posInView    = half3((uniforms.modelView * float4((currentPos - 0.5),1)).xyz);
          half3 normalInView = half3(normalize((uniforms.modelViewIT * float4(normal,0)).xyz));
          current.rgb += float3(lighting(posInView, normalInView, half3(current.rgb)));
        }

        accColor = underFloat(current, accColor);

        // Early ray termination on high opacity
        if (accColor.a > 0.99) return half4(accColor);
        poolCoords += voxelSpaceDirection;
      }
    }

    // Advance to the next brick
    currentPos = brickResult.normExitCoords + (stepEpsilon * direction / rayLength);
    t = length(entryPoint - brickResult.normExitCoords) / rayLength;

    // Safety cap to prevent infinite loops
    brickCount++;
    if (brickCount == MAX_ITERATIONS) return half4(accColor);
  }

  return half4(accColor);
}

// MARK: - Isosurface Fragment Shader

/**
 Performs volume raymarching for isosurface rendering.

 - Parameters: Similar to `fragmentShaderTF`, but uses a fixed isoValue threshold.
 - Returns: The shaded color at the isosurface intersection, or transparent if none found.
 */
fragment half4 macOSFragmentShaderIso(
                                 VertexToFragment in [[stage_in]],
                                 texture3d<half> volumeAtlas                      [[texture(TextureIndexVolumeAtlas)]],
                                 device const FragmentUniformsArray& uniformsArray [[buffer(FragmentBufferIndexUniforms)]],
                                 device const LevelData* levelData                 [[buffer(FragmentBufferIndexLevelTable)]],
                                 device const uint* brickMeta                    [[buffer(FragmentBufferIndexBrickMeta)]],
                                 device atomic_uint* hashBuffer                    [[buffer(FragmentBufferIndexHashTable)]]
                                 ) {
  FragmentUniforms uniforms = uniformsArray.uniforms[0];
  constexpr sampler s(address::clamp_to_border, filter::linear);
  float3 stepEpsilon = 0.125 / POOL_SIZE;

  float3 exitPoint  = in.exitPoint;
  float3 entryPoint = computeEntryPoint(uniforms.cameraPosInTextureSpace, exitPoint, uniforms);

  float3 direction = normalize(exitPoint - entryPoint);
  entryPoint += direction * stepEpsilon;
  direction = exitPoint - entryPoint;
  float rayLength = length(direction);

  if (rayLength < length(stepEpsilon)) return half4(0);

  float entryDepth = length(uniforms.cameraPosInTextureSpaceVoxelScaled - entryPoint);
  float exitDepth  = length(uniforms.cameraPosInTextureSpaceVoxelScaled - exitPoint);

  float3 voxelSpaceDirection = transformToPoolSpace(direction, uniforms.oversampling);
  float  stepSize            = length(voxelSpaceDirection);

  float3 currentPos = entryPoint;
  float t           = 0;
  uint  brickCount  = 0;

  while (t < 0.9999) {
    float currentDepth = mix(entryDepth, exitDepth, t);
    uint  iLOD         = computeLOD(currentDepth);

    BrickInformation brickResult = getBrick(
                                            currentPos, iLOD, direction,
                                            uniforms.cubeBounds,
                                            brickMeta, levelData,
                                            hashBuffer, false
                                            );
#if STOP_ON_MISS == 1
    if (brickResult.substitute) return half4(0);
#endif
    
    if (!brickResult.empty) {
      int iSteps = int(ceil(
                            length(brickResult.poolBrickInfo.poolExitCoords
                                   - brickResult.poolBrickInfo.poolEntryCoords) / stepSize
                            ));
      iSteps = min(int(2*BRICK_SIZE*uniforms.oversampling),iSteps);
      for (int i = 0; i < iSteps; ++i) {
        float3 poolCoords = mix(
                                brickResult.poolBrickInfo.poolEntryCoords,
                                brickResult.poolBrickInfo.poolExitCoords,
                                i / float(iSteps)
                                );
        float value = volumeAtlas.sample(s, poolCoords).r;
        if (value >= uniforms.isoValue) {
          poolCoords = refineIsosurface(
                                        voxelSpaceDirection,
                                        poolCoords,
                                        uniforms.isoValue,
                                        volumeAtlas,
                                        s
                                        );
          float3 normal = computeNormal(
                                        poolCoords, POOL_SIZE,
                                        float3(1,1,1),
                                        volumeAtlas,
                                        s
                                        );
          half3 posInView    = half3((uniforms.modelView * float4((currentPos - 0.5),1)).xyz);
          half3 normalInView = half3(normalize((uniforms.modelViewIT * float4(normal,0)).xyz));
          half3 color = lighting(posInView, normalInView, half3(0.5,0.5,0.5));
          return half4(color, 1);
        }
      }
    }

    currentPos = brickResult.normExitCoords + (stepEpsilon * direction / rayLength);
    t = length(entryPoint - brickResult.normExitCoords) / rayLength;

    // Safety cap to prevent infinite loops
    brickCount++;
    if (brickCount == MAX_ITERATIONS) return half4(0);
  }

  return half4(0);
}

// MARK: - Brick Visualization Fragment Shader

/**
 Visualizes brick occupancy by coloring empty vs. loaded bricks along the ray.

 - If a brick is empty, adds a semi-transparent green.
 - If loaded, adds a semi-transparent red.
 */
fragment half4 macOSFragmentShaderBrickVis(
                                      VertexToFragment in [[stage_in]],
                                      device const FragmentUniformsArray& uniformsArray [[buffer(FragmentBufferIndexUniforms)]],
                                      device const LevelData* levelData                 [[buffer(FragmentBufferIndexLevelTable)]],
                                      device const uint* brickMeta                    [[buffer(FragmentBufferIndexBrickMeta)]],
                                      device atomic_uint* hashBuffer                    [[buffer(FragmentBufferIndexHashTable)]]
                                      ) {
  FragmentUniforms uniforms = uniformsArray.uniforms[0];
  float3 stepEpsilon = 0.125 / POOL_SIZE;

  float3 exitPoint  = in.exitPoint;
  float3 entryPoint = computeEntryPoint(uniforms.cameraPosInTextureSpace, exitPoint, uniforms);

  float3 direction = normalize(exitPoint - entryPoint);
  entryPoint += direction * stepEpsilon;
  direction = exitPoint - entryPoint;
  float rayLength = length(direction);

  if (rayLength < length(stepEpsilon)) return half4(0);

  float entryDepth = length(uniforms.cameraPosInTextureSpaceVoxelScaled - entryPoint);
  float exitDepth  = length(uniforms.cameraPosInTextureSpaceVoxelScaled - exitPoint);

  float3 currentPos = entryPoint;
  half4 accColor    = half4(0);
  float t           = 0;
  uint  brickCount  = 0;

  while (t < 0.9999) {
    float currentDepth = mix(entryDepth, exitDepth, t);
    uint  iLOD         = computeLOD(currentDepth);

    BrickInformation brickResult = getBrick(
                                            currentPos, iLOD, direction,
                                            uniforms.cubeBounds,
                                            brickMeta, levelData,
                                            hashBuffer, true
                                            );

    // Color code: empty bricks green, loaded bricks red
    if (brickResult.empty) {
      accColor += half4(0, 0.1, 0, 0.1);
    } else {
      accColor += half4(0.1, 0, 0, 0.1);
    }

    currentPos = brickResult.normExitCoords + (stepEpsilon * direction / rayLength);
    t = length(entryPoint - brickResult.normExitCoords) / rayLength;

    // Safety cap to prevent infinite loops
    brickCount++;
    if (brickCount == MAX_ITERATIONS) return accColor;
  }

  return accColor;
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
