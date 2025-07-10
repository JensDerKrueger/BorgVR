#ifndef VolumeAtlas_h
#define VolumeAtlas_h

#include "GPUHashtable.h"

using namespace metal;

uint getBrickIndex(uint4 brickCoords, device const LevelData *levelArray) {
  LevelData level  = levelArray[brickCoords.w];
  return level.prevBricks +
         brickCoords.x +
         brickCoords.y * level.bricksX +
         brickCoords.z * level.bricksXTimesBricksY;
}

uint4 computeBrickCoords(float3 normEntryCoords,
                         device const LevelData *levelArray, uint LOD) {
  LevelData level = levelArray[LOD];
  return uint4(uint3(normEntryCoords*level.fractionalBrickLayout), LOD);
}

struct BrickCorners {
  float3 values[2];
};

BrickCorners getBrickCorners(uint4 brickCoords, device const LevelData *levelArray) {
  BrickCorners c;
  c.values[0] = float3(brickCoords.xyz)   / levelArray[brickCoords.w].fractionalBrickLayout;
  c.values[1] = float3(brickCoords.xyz+1) / levelArray[brickCoords.w].fractionalBrickLayout;
  return c;
}

float3 brickExit(float3 pointInBrick, float3 dir, float3 cubeBounds[2],
                 BrickCorners corners) {
  float3 div = 1.0 / dir;
  uint3 side = uint3(step(0.0,div));
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
  uint brickID = brickInfo-BI_FLAG_COUNT;
  uint3 vBrickCoords;
  vBrickCoords.x = brickID % POOL_CAPACITY.x;
  vBrickCoords.y = (brickID / POOL_CAPACITY.x) % POOL_CAPACITY.y;
  vBrickCoords.z = brickID / (POOL_CAPACITY.x*POOL_CAPACITY.y);
  return vBrickCoords;
}

BrickCorners brickPoolCoords(uint brickInfo) {
  uint3 poolVoxelPos = infoToCoords(brickInfo) * BRICK_SIZE;
  BrickCorners c;
  c.values[0] = (float3(poolVoxelPos)            / POOL_SIZE)+ OVERLAP_STEP;
  c.values[1] = (float3(poolVoxelPos+BRICK_SIZE) / POOL_SIZE)- OVERLAP_STEP;
  return c;
}

struct PoolBrickInformation {
  float3 poolEntryCoords;   // pool-local coordinates of the brick entry point
  float3 poolExitCoords;    // pool-local coordinates of the brick exit point
  float3 normToPoolScale;   // scaling from dataset to brick coordinates
  float3 normToPoolTrans;   // translation from dataset to brick coordinates
};

PoolBrickInformation normCoordsToPoolCoords(float3 normEntryCoords,
                                            float3 normExitCoords,
                                            BrickCorners corners,
                                            uint brickInfo) {
  PoolBrickInformation info;
  BrickCorners poolCorners = brickPoolCoords(brickInfo);
  info.normToPoolScale = (poolCorners.values[1]-poolCorners.values[0])/(corners.values[1]-corners.values[0]);
  info.normToPoolTrans = poolCorners.values[0]-corners.values[0]*info.normToPoolScale;
  info.poolEntryCoords  = (normEntryCoords * info.normToPoolScale + info.normToPoolTrans);
  info.poolExitCoords   = (normExitCoords  * info.normToPoolScale + info.normToPoolTrans);
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

BrickInformation getBrick(float3 normEntryCoords, uint iLOD,
                          float3 direction,
                          float3 cubeBounds[2],
                          device const uint *brickMeta,
                          device const LevelData *levelArray,
                          device atomic_uint* hashBuffer,
                          bool dontRequest) {

  BrickInformation info;
  info.LOD = iLOD;

  normEntryCoords = clamp(normEntryCoords,float3(0),float3(1));

  uint4 brickCoords = computeBrickCoords(normEntryCoords, levelArray, info.LOD);
  uint  brickIndex  = getBrickIndex(brickCoords, levelArray);
  uint  brickInfo   = brickMeta[brickIndex];

  info.brickIndex = brickIndex;
  info.substitute = brickInfo == BI_MISSING;

  // cache miss
  if (!dontRequest && brickInfo == BI_MISSING) {
    reportMissingBrick(brickIndex, hashBuffer);

    // look for lower res
    uint startLOD = info.LOD;
    int lastBrickIndex = brickIndex;
    do {
      lastBrickIndex = brickIndex;
      info.LOD++;
      brickCoords = computeBrickCoords(normEntryCoords, levelArray, info.LOD);
      brickIndex  = getBrickIndex(brickCoords, levelArray);
      brickInfo   = brickMeta[brickIndex];
    } while (brickInfo == BI_MISSING);

#if REQUEST_LOWRES_LOD == 1
    if(startLOD < info.LOD) {
      reportMissingBrick(lastBrickIndex,hashBuffer);
    }
#endif
  }

  // next line check for BI_EMPTY or BI_CHILD_EMPTY (BI_MISSING is
  // excluded by code above!)
  info.empty = (brickInfo <= BI_EMPTY);
  if (info.empty) {
    // when we find an empty brick check if the lower resolutions are also empty
    // this allows us to potentially skip a larger region
    for (uint lowResLOD = info.LOD+1; lowResLOD<LEVEL_COUNT;++lowResLOD) {
      uint4 lowResBrickCoords = computeBrickCoords(normEntryCoords, levelArray, lowResLOD);
      uint lowResBrickIndex  = getBrickIndex(lowResBrickCoords, levelArray);
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
  return min(uint(LEVEL_COUNT-1),
             uint(log2(LOD_FACTOR*(dist)/LEVEL_ZERO_WORLD_SPACE_ERROR)));
}

float3 getSampleDelta() {
  return 1.0/POOL_SIZE;
}

float3 transformToPoolSpace(float3 direction, float sampleRateModifier) {
  // normalize the direction
  direction *= VOLUME_SIZE;
  direction = normalize(direction);
  // scale to volume pool's norm coordinates
  direction /= POOL_SIZE;
  // do (roughly) two samples per voxel and apply user defined sample density
  return direction / (2.0*sampleRateModifier);
}


#endif

