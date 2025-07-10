//
//  Shaders.metal
//
//  File for Metal kernel and shader functions
//

#include <metal_stdlib>
#include <simd/simd.h>

// Including header shared between this Metal shader code and Swift/C code executing Metal API commands
#import "ShaderTypes.h"
#include "VolumeAtlas.h"
#include "Helper.h"

using namespace metal;

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
vertex VertexToFragment vertexShader(
                                     uint vertexId [[vertex_id]],
                                     ushort amp_id [[amplification_id]],
                                     device const Vertex* in [[buffer(VertexBufferIndexMeshPositions)]],
                                     constant VertexUniformsArray& uniformsArray [[buffer(VertexBufferIndexUniforms)]]
                                     ) {
  VertexUniforms uniforms = uniformsArray.uniforms[amp_id];
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
fragment half4 fragmentShaderTF(
                                VertexToFragment in [[stage_in]],
                                ushort amp_id [[amplification_id]],
                                texture3d<half> volumeAtlas   [[texture(TextureIndexVolumeAtlas)]],
                                texture1d<half> transferFunc  [[texture(TextureIndexTransferFunction)]],
                                device const FragmentUniformsArray& uniformsArray [[buffer(FragmentBufferIndexUniforms)]],
                                device const LevelData* levelData                [[buffer(FragmentBufferIndexLevelTable)]],
                                device const uint* brickMeta                     [[buffer(FragmentBufferIndexBrickMeta)]],
                                device atomic_uint* hashBuffer                   [[buffer(FragmentBufferIndexHashTable)]]
                                ) {
  FragmentUniforms uniforms = uniformsArray.uniforms[amp_id];
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
  half4 accColor    = half4(0);
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
    if (brickResult.substitute) return accColor;
#endif
    
    if (!brickResult.empty) {
      // Number of samples within this brick
      int iSteps = int(ceil(
                            length(brickResult.poolBrickInfo.poolExitCoords
                                   - brickResult.poolBrickInfo.poolEntryCoords) / stepSize
                            ));
      float ocFactor = float(1 << iLOD) / uniforms.oversampling;

      // Sample along the ray segment in this brick
      for (int i = 0; i < iSteps; ++i) {
        float3 poolCoords = mix(
                                brickResult.poolBrickInfo.poolEntryCoords,
                                brickResult.poolBrickInfo.poolExitCoords,
                                i / float(iSteps)
                                );
        float volumeValue = volumeAtlas.sample(s, poolCoords).r;
        half4 current = transferFunc.sample(s, volumeValue * uniforms.transferBias);
        // Opacity correction
        current.a = 1.0 - pow(1.0 - current.a, ocFactor);
        accColor = under(current, accColor);

        // Early ray termination on high opacity
        if (accColor.a > 0.99) return accColor;
        poolCoords += voxelSpaceDirection;
      }
    }

    // Advance to the next brick
    currentPos = brickResult.normExitCoords + (stepEpsilon * direction / rayLength);
    t = length(entryPoint - currentPos) / rayLength;

    // Safety cap to prevent infinite loops
    brickCount++;
    if (brickCount == MAX_ITERATIONS) return accColor;
  }

  return accColor;
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
fragment half4 fragmentShaderTFLighting(
                                VertexToFragment in [[stage_in]],
                                ushort amp_id [[amplification_id]],
                                texture3d<half> volumeAtlas   [[texture(TextureIndexVolumeAtlas)]],
                                texture1d<half> transferFunc  [[texture(TextureIndexTransferFunction)]],
                                device const FragmentUniformsArray& uniformsArray [[buffer(FragmentBufferIndexUniforms)]],
                                device const LevelData* levelData                [[buffer(FragmentBufferIndexLevelTable)]],
                                device const uint* brickMeta                   [[buffer(FragmentBufferIndexBrickMeta)]],
                                device atomic_uint* hashBuffer                   [[buffer(FragmentBufferIndexHashTable)]]
                                ) {
  FragmentUniforms uniforms = uniformsArray.uniforms[amp_id];
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
  half4 accColor    = half4(0);
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
    if (brickResult.substitute) return accColor;
#endif

    if (!brickResult.empty) {
      // Number of samples within this brick
      int iSteps = int(ceil(
                            length(brickResult.poolBrickInfo.poolExitCoords
                                   - brickResult.poolBrickInfo.poolEntryCoords) / stepSize
                            ));
      float ocFactor = float(1 << iLOD) / uniforms.oversampling;

      // Sample along the ray segment in this brick
      for (int i = 0; i < iSteps; ++i) {
        float3 poolCoords = mix(
                                brickResult.poolBrickInfo.poolEntryCoords,
                                brickResult.poolBrickInfo.poolExitCoords,
                                i / float(iSteps)
                                );
        float volumeValue = volumeAtlas.sample(s, poolCoords).r;
        half4 current = transferFunc.sample(s, volumeValue * uniforms.transferBias);
        // Opacity correction
        current.a = 1.0 - pow(1.0 - current.a, ocFactor);

        if (current.a > 0.01)
        {
          float3 normal = computeNormal(
                                        poolCoords, POOL_SIZE,
                                        float3(1,1,1),
                                        volumeAtlas,
                                        s
                                        );

          half3 posInView    = half3((uniforms.modelView * float4((currentPos - 0.5),1)).xyz);
          half3 normalInView = half3(normalize((uniforms.modelViewIT * float4(normal,0)).xyz));
          current.rgb += lighting(posInView, normalInView, current.rgb);
          accColor = under(current, accColor);

          // Early ray termination on high opacity
          if (accColor.a > 0.99) return accColor;
        }
        poolCoords += voxelSpaceDirection;
      }
    }

    // Advance to the next brick
    currentPos = brickResult.normExitCoords + (stepEpsilon * direction / rayLength);
    t = length(entryPoint - brickResult.normExitCoords) / rayLength;

    // Safety cap to prevent infinite loops
    brickCount++;
    if (brickCount == MAX_ITERATIONS) return accColor;
  }

  return accColor;
}

// MARK: - Isosurface Fragment Shader

/**
 Performs volume raymarching for isosurface rendering.

 - Parameters: Similar to `fragmentShaderTF`, but uses a fixed isoValue threshold.
 - Returns: The shaded color at the isosurface intersection, or transparent if none found.
 */
fragment half4 fragmentShaderIso(
                                 VertexToFragment in [[stage_in]],
                                 ushort amp_id [[amplification_id]],
                                 texture3d<half> volumeAtlas                      [[texture(TextureIndexVolumeAtlas)]],
                                 device const FragmentUniformsArray& uniformsArray [[buffer(FragmentBufferIndexUniforms)]],
                                 device const LevelData* levelData                 [[buffer(FragmentBufferIndexLevelTable)]],
                                 device const uint* brickMeta                    [[buffer(FragmentBufferIndexBrickMeta)]],
                                 device atomic_uint* hashBuffer                    [[buffer(FragmentBufferIndexHashTable)]]
                                 ) {
  FragmentUniforms uniforms = uniformsArray.uniforms[amp_id];
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
    if (brickResult.substitute) return half4(0,0,0,1);
#endif
    
    if (!brickResult.empty) {
      int iSteps = int(ceil(
                            length(brickResult.poolBrickInfo.poolExitCoords
                                   - brickResult.poolBrickInfo.poolEntryCoords) / stepSize
                            ));
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
fragment half4 fragmentShaderBrickVis(
                                      VertexToFragment in [[stage_in]],
                                      ushort amp_id [[amplification_id]],
                                      device const FragmentUniformsArray& uniformsArray [[buffer(FragmentBufferIndexUniforms)]],
                                      device const LevelData* levelData                 [[buffer(FragmentBufferIndexLevelTable)]],
                                      device const uint* brickMeta                    [[buffer(FragmentBufferIndexBrickMeta)]],
                                      device atomic_uint* hashBuffer                    [[buffer(FragmentBufferIndexHashTable)]]
                                      ) {
  FragmentUniforms uniforms = uniformsArray.uniforms[amp_id];
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

    brickCount++;
    if (brickCount == MAX_ITERATIONS) return accColor;
  }

  return accColor;
}

/*
 Copyright (c) 2025 Computer Graphics and Visualization Group, University of Duisburg-
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
