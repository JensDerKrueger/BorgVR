//
//  ShaderTypes.h
//
//  Header containing types and enum constants shared between Metal shaders and Swift/ObjC source
//

#ifndef ShaderTypes_h
#define ShaderTypes_h

#ifdef __METAL_VERSION__
#define NS_ENUM(_type, _name) enum _name : _type _name; enum _name : _type
/// Under Metal, use 32-bit signed integer as the backing type for enums.
typedef metal::int32_t EnumBackingType;
#else
#import <Foundation/Foundation.h>
/// In Swift/Objective-C, use NSInteger as the backing type for enums.
typedef NSInteger EnumBackingType;
#endif

#include <simd/simd.h>

/// Dummy values (overridden when the shader is loaded with the real values)
#ifndef OVERRIDE_DUMMY
#define LEVEL_COUNT 10                      ///< Number of LOD levels in the volume hierarchy.
#define BRICK_SIZE 64                       ///< Edge length of each brick in voxels.
#define BRICK_INNER_SIZE 60                 ///< Inner voxel count per brick (excluding overlap).
#define OVERLAP_STEP float3(1,1,1)          ///< Step size for overlap regions between bricks.
#define LEVEL_ZERO_WORLD_SPACE_ERROR 1.0    ///< Base world-space error at LOD 0.
#define LOD_FACTOR 1.0                      ///< Factor used to compute LOD.
#define POOL_CAPACITY uint3(1,1,1)          ///< Initial capacity of the brick cache pool.
#define POOL_SIZE float3(1,1,1)             ///< Physical size of the pool in bricks.
#define VOLUME_SIZE float3(1,1,1)           ///< Size of the volume in normalized texture space.
#define HASHTABLE_SIZE 128                  ///< Number of entries in the GPU hash table.
#define MAX_PROBING_ATTEMPTS 10             ///< Maximum linear probing attempts in the hash table before giving up
#define MAX_ITERATIONS 100                  ///< Maximum number of bricks traversed by the raycaster
#define REQUEST_LOWRES_LOD 1                ///< Whether to request a low resolution LOD along with the high res
#define STOP_ON_MISS 0                      ///< Whether the raycaster should terminate if a brick is missing
#endif

/**
 BrickIDFlags:
 Flags indicating the page state of a brick in the volume cache.

 - BI_MISSING:      Brick is not paged in yet.
 - BI_CHILD_EMPTY:  Brick and all finer-level children are empty.
 - BI_EMPTY:        Brick is empty (but finer levels may contain data).
 - BI_FLAG_COUNT:   Number of flag values (offset to subtract from brick indices).
 */
typedef NS_ENUM(EnumBackingType, BrickIDFlags)
{
  BI_MISSING       = 0,
  BI_CHILD_EMPTY   = 1,
  BI_EMPTY         = 2,
  BI_FLAG_COUNT    = 3
};

/**
 VertexBufferIndex:
 Indices for vertex buffer bindings in Metal shaders.
 */
typedef NS_ENUM(EnumBackingType, VertexBufferIndex)
{
  VertexBufferIndexMeshPositions = 0,  ///< Buffer containing mesh vertex positions.
  VertexBufferIndexUniforms      = 1   ///< Buffer containing per-frame uniforms.
};

/**
 FragmentBufferIndex:
 Indices for fragment buffer bindings in Metal shaders.
 */
typedef NS_ENUM(EnumBackingType, FragmentBufferIndex)
{
  FragmentBufferIndexUniforms   = 0,  ///< Buffer containing fragment uniforms.
  FragmentBufferIndexLevelTable = 1,  ///< Buffer containing LOD level information.
  FragmentBufferIndexBrickMeta  = 2,  ///< Buffer containing per-brick metadata.
  FragmentBufferIndexHashTable  = 3   ///< Buffer used as the GPU-side hash table.
};

/**
 TextureIndex:
 Indices for texture bindings in Metal shaders.
 */
typedef NS_ENUM(EnumBackingType, TextureIndex)
{
  TextureIndexVolumeAtlas      = 0,   ///< 3D texture atlas containing brick data.
  TextureIndexTransferFunction = 1    ///< 1D transfer function texture.
};

/**
 FragmentUniforms:
 Struct of parameters passed to the fragment shader for volume rendering.

 - isoValue:                        Threshold for isosurface rendering.
 - oversampling:                   Raymarching oversampling factor.
 - transferBias:                   Bias for transfer function lookup.
 - cameraPosInTextureSpace:        Camera position in normalized texture coords.
 - cameraPosInTextureSpaceVoxelScaled:
 Camera position scaled by volume dimensions.
 - cubeBounds:                     Axis-aligned bounding box of the volume (min, max).
 - modelView:                      Model-view matrix for transforming positions.
 - modelViewIT:                    Inverse-transpose of the model-view for normals.
 */
typedef struct {
  float isoValue;
  float oversampling;
  float transferBias;
  vector_float3 cameraPosInTextureSpace;
  vector_float3 cameraPosInTextureSpaceVoxelScaled;
  vector_float3 cubeBounds[2];
  matrix_float4x4 modelView;
  matrix_float4x4 modelViewIT;
} FragmentUniforms;

/**
 FragmentUniformsArray:
 An array wrapper for left and right eye.
 */
typedef struct {
  FragmentUniforms uniforms[2];
} FragmentUniformsArray;

/**
 VertexUniforms:
 Struct of parameters passed to the vertex shader.

 - modelViewProjectionMatrix:     Combined model-view-projection matrix.
 - clipMatrix:                    Additional clipping matrix.
 */
typedef struct {
  matrix_float4x4 modelViewProjectionMatrix;
  matrix_float4x4 clipMatrix;
} VertexUniforms;

/**
 VertexUniformsArray:
 An array wrapper for double-buffered vertex uniforms.
 */
typedef struct {
  VertexUniforms uniforms[2];
} VertexUniformsArray;

/**
 Vertex:
 Per-vertex input structure for position data.

 - position: 3D vertex position in model space.
 */
typedef struct {
  simd_float3 position;
} Vertex;

/**
 LevelData:
 Metadata for each LOD level in the brick hierarchy.

 - bricksX:               Number of bricks along the X axis.
 - bricksXTimesBricksY:   Number of bricks in a single slice (X × Y).
 - prevBricks:            Total bricks in all coarser levels.
 - fractionalBrickLayout: Fractional layout scaling for sampling.
 */
typedef struct {
  uint        bricksX;
  uint        bricksXTimesBricksY;
  uint        prevBricks;
  simd_float3 fractionalBrickLayout;
} LevelData;

#endif /* ShaderTypes_h */

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
