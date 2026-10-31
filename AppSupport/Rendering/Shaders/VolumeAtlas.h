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
#if VOLUME_SUBBRICK_SKIPPING
  uint pageIndex;
#endif
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
                          bool dontRequest,
                          bool useResidentFallback = false) {

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
  if ((!dontRequest || useResidentFallback) && brickInfo == BI_MISSING) {
    if (!dontRequest) reportMissingBrick(brickIndex, hashBuffer);

    // look for lower res
    uint startLOD = info.LOD;
    int lastBrickIndex = brickIndex;
    while (brickInfo == BI_MISSING && info.LOD + 1 < LEVEL_COUNT) {
      lastBrickIndex = brickIndex;
      info.LOD++;
      brickCoords = computeBrickCoords(normEntryCoords, levelArray,
                                       info.LOD, direction);
      brickIndex  = getBrickIndex(brickCoords, levelArray);
      brickInfo   = brickMeta[brickIndex];
    }

#if REQUEST_LOWRES_LOD == 1
    if(!dontRequest && startLOD < info.LOD) {
      reportMissingBrick(lastBrickIndex,hashBuffer);
    }
#endif
  }

  // Missing data also skips sampling when no resident fallback is available.
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

#if VOLUME_SUBBRICK_SKIPPING
  info.pageIndex = brickInfo - BI_FLAG_COUNT;
#endif

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

#if VOLUME_SUBBRICK_SKIPPING
#ifndef VOLUME_SUBBRICK_DIVISIONS
#define VOLUME_SUBBRICK_DIVISIONS 2
#endif
#define SUBBRICK_CELL_COUNT (VOLUME_SUBBRICK_DIVISIONS * VOLUME_SUBBRICK_DIVISIONS * VOLUME_SUBBRICK_DIVISIONS)
#define SUBBRICK_MASK_STRIDE (1 + (SUBBRICK_CELL_COUNT + 31) / 32)

bool subbrickCellVisible(device const uint *masks, uint page, uint cell) {
  return (masks[page * SUBBRICK_MASK_STRIDE + 1 + cell / 32] & (1u << (cell & 31))) != 0;
}

int3 subbrickParallelCell(float3 local) {
  float overlap = float((BRICK_SIZE - BRICK_INNER_SIZE) / 2);
  uint3 voxel = uint3(max(local - overlap, float3(0)));
  return int3(min(((voxel + 1) * VOLUME_SUBBRICK_DIVISIONS - 1) / BRICK_INNER_SIZE,
                  uint3(VOLUME_SUBBRICK_DIVISIONS - 1)));
}

struct SubbrickSampleTraversal {
  int3 cuts[VOLUME_SUBBRICK_DIVISIONS > 1 ? VOLUME_SUBBRICK_DIVISIONS - 1 : 1];
  int3 initialCell;
  int3 direction;
};

SubbrickSampleTraversal prepareSubbrickTraversal(PoolBrickInformation pool, uint pageIndex,
                                                 int steps, float phase) {
  float3 start = pool.poolEntryCoords * POOL_SIZE - float3(infoToCoords(pageIndex + BI_FLAG_COUNT) * BRICK_SIZE);
  float3 delta = (pool.poolExitCoords - pool.poolEntryCoords) * POOL_SIZE;
  bool3 changing = abs(delta) > 1e-7;
  SubbrickSampleTraversal result;
  result.initialCell = select(subbrickParallelCell(start),
    select(int3(0), int3(VOLUME_SUBBRICK_DIVISIONS - 1), delta < 0), changing);
  result.direction = select(int3(0), select(int3(1), int3(-1), delta < 0), changing);
  #pragma unroll
  for (int plane = 1; plane < VOLUME_SUBBRICK_DIVISIONS; ++plane) {
    float boundary = float((BRICK_SIZE - BRICK_INNER_SIZE) / 2 +
                            plane * BRICK_INNER_SIZE / VOLUME_SUBBRICK_DIVISIONS);
    float3 cut = ceil((boundary - start) / select(float3(1), delta, changing) * float(steps) - phase);
    result.cuts[plane - 1] = select(int3(steps), int3(clamp(cut, float3(0), float3(steps))), changing);
  }
  return result;
}

// Return a span of the original sample indices, never a new sampling phase.
int subbrickSampleEnd(SubbrickSampleTraversal traversal, int index, int steps,
                      thread uint &cell) {
  int3 coordinate = traversal.initialCell, ends = int3(steps);
  #pragma unroll
  for (int plane = 0; plane < VOLUME_SUBBRICK_DIVISIONS - 1; ++plane) {
    bool3 crossed = int3(index) >= traversal.cuts[plane];
    coordinate += int3(crossed) * traversal.direction;
    ends = min(ends, select(traversal.cuts[plane], int3(steps), crossed));
  }
  cell = uint(coordinate.x + VOLUME_SUBBRICK_DIVISIONS *
              (coordinate.y + VOLUME_SUBBRICK_DIVISIONS * coordinate.z));
  return min(ends.x, min(ends.y, ends.z));
}

// Continuous traversal for the diagnostic view, including empty/missing bricks.
float subbrickRayEnd(float3 start, float3 delta, float t, thread uint &cell) {
  bool3 changing = abs(delta) > 1e-7;
  int3 coordinate = select(subbrickParallelCell(start),
    select(int3(0), int3(VOLUME_SUBBRICK_DIVISIONS - 1), delta < 0), changing);
  int3 step = select(int3(0), select(int3(1), int3(-1), delta < 0), changing);
  float3 end = float3(1);
  for (int plane = 1; plane < VOLUME_SUBBRICK_DIVISIONS; ++plane) {
    float boundary = float((BRICK_SIZE - BRICK_INNER_SIZE) / 2 +
                            plane * BRICK_INNER_SIZE / VOLUME_SUBBRICK_DIVISIONS);
    float3 cut = (boundary - start) / select(float3(1), delta, changing);
    bool3 crossed = cut <= t;
    coordinate += int3(crossed) * step;
    end = min(end, select(float3(1), cut, changing & !crossed));
  }
  cell = uint(coordinate.x + VOLUME_SUBBRICK_DIVISIONS *
              (coordinate.y + VOLUME_SUBBRICK_DIVISIONS * coordinate.z));
  return min(end.x, min(end.y, end.z));
}
#endif

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
