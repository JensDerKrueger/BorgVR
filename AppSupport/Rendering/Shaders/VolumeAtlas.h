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
                         device const LevelData *levelArray,
                         uint LOD,
                         float3 direction) {
  LevelData level = levelArray[LOD];
  float3 scaledCoords = clamp(normEntryCoords, float3(0), float3(1)) *
                        level.fractionalBrickLayout;
  uint3 maxCoords = max(uint3(ceil(level.fractionalBrickLayout)), uint3(1)) -
                    uint3(1);
  float3 nearestBoundary = round(scaledCoords);
  float3 boundaryDistance = abs(scaledCoords - nearestBoundary);

  // Snap lookup coordinates that are numerically on a brick boundary. Positive
  // rays naturally belong to the brick after the boundary; negative rays need
  // a tiny lookup-only bias to select the brick before it. Sampling still uses
  // the original, unbiased normEntryCoords.
  if (boundaryDistance.x <= 1e-5) {
    scaledCoords.x = direction.x < 0.0 ? nearestBoundary.x - 1e-5 :
                                        nearestBoundary.x;
  }
  if (boundaryDistance.y <= 1e-5) {
    scaledCoords.y = direction.y < 0.0 ? nearestBoundary.y - 1e-5 :
                                        nearestBoundary.y;
  }
  if (boundaryDistance.z <= 1e-5) {
    scaledCoords.z = direction.z < 0.0 ? nearestBoundary.z - 1e-5 :
                                        nearestBoundary.z;
  }

  return uint4(min(uint3(max(scaledCoords, float3(0))), maxCoords), LOD);
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

float3 inverseBrickRayDirection(float3 direction) {
  bool3 parallel = abs(direction) < 1e-8;
  return select(1.0 / select(direction, float3(1.0), parallel), float3(0), parallel);
}

float brickAxisExit(float point, float dir, float inverseDir, float brickMin, float brickMax,
                    float cubeMin, float cubeMax) {
  const float eps = 1e-8;
  if (abs(dir) < eps) {
    return INFINITY;
  }

  float boundary = dir > 0.0 ? min(brickMax, cubeMax) : max(brickMin, cubeMin);
  return max((boundary - point) * inverseDir, 0.0);
}

float brickExitParameter(float3 pointInBrick, float3 dir, float3 inverseDir,
                         float3 cubeBounds[2], BrickCorners corners) {
  float3 tIntersect = float3(
    brickAxisExit(pointInBrick.x, dir.x, inverseDir.x, corners.values[0].x, corners.values[1].x,
                  cubeBounds[0].x, cubeBounds[1].x),
    brickAxisExit(pointInBrick.y, dir.y, inverseDir.y, corners.values[0].y, corners.values[1].y,
                  cubeBounds[0].y, cubeBounds[1].y),
    brickAxisExit(pointInBrick.z, dir.z, inverseDir.z, corners.values[0].z, corners.values[1].z,
                  cubeBounds[0].z, cubeBounds[1].z)
  );

  return min(min(tIntersect.x, tIntersect.y), tIntersect.z);
}

uint3 infoToCoords(uint brickInfo) {
  uint brickID = brickInfo-BI_FLAG_COUNT;
  uint3 vBrickCoords;
  vBrickCoords.x = brickID % POOL_CAPACITY.x;
  vBrickCoords.y = (brickID / POOL_CAPACITY.x) % POOL_CAPACITY.y;
  vBrickCoords.z = brickID / (POOL_CAPACITY.x*POOL_CAPACITY.y);
  return vBrickCoords;
}

struct PoolBrickInformation {
  float3 poolEntryCoords;   // pool-local coordinates of the brick entry point
  float3 poolExitCoords;    // pool-local coordinates of the brick exit point
};

PoolBrickInformation normCoordsToPoolCoords(float3 normEntryCoords,
                                            float3 normExitCoords,
                                            BrickCorners corners,
                                            float3 fractionalBrickLayout,
                                            uint brickInfo) {
  PoolBrickInformation info;
  float3 poolMin = float3(infoToCoords(brickInfo) * BRICK_SIZE) / POOL_SIZE + OVERLAP_STEP;
  float3 scale = fractionalBrickLayout * (float(BRICK_INNER_SIZE) / POOL_SIZE);
  info.poolEntryCoords = (normEntryCoords - corners.values[0]) * scale + poolMin;
  info.poolExitCoords = (normExitCoords - corners.values[0]) * scale + poolMin;
  return info;
}

struct BrickInformation {
  uint LOD;
  uint brickIndex;
  bool empty;
  bool substitute;
  float rayExitDelta;       // increment of the original entry-to-exit ray parameter
  float3 normExitCoords;
  PoolBrickInformation poolBrickInfo;
};

BrickInformation getBrick(float3 normEntryCoords, uint iLOD,
                          float3 direction,
                          float3 inverseDirection,
                          float3 cubeBounds[2],
                          device const uint *brickMeta,
                          device const LevelData *levelArray,
                          device atomic_uint* hashBuffer,
                          bool dontRequest) {

  BrickInformation info;
  info.LOD = iLOD;

  normEntryCoords = clamp(normEntryCoords,float3(0),float3(1));

  uint4 brickCoords = computeBrickCoords(normEntryCoords, levelArray,
                                         info.LOD, direction);
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
      brickCoords = computeBrickCoords(normEntryCoords, levelArray,
                                       info.LOD, direction);
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
      uint4 lowResBrickCoords = computeBrickCoords(normEntryCoords, levelArray,
                                                   lowResLOD, direction);
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
  info.rayExitDelta = brickExitParameter(normEntryCoords, direction, inverseDirection,
                                        cubeBounds, corners);
  info.normExitCoords = normEntryCoords + info.rayExitDelta * direction;
  if (info.empty) return info;

  info.poolBrickInfo = normCoordsToPoolCoords(normEntryCoords,
                                              info.normExitCoords,
                                              corners,
                                              levelArray[info.LOD].fractionalBrickLayout,
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
