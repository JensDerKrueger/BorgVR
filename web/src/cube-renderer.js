import { BrickAtlas } from "./brick-atlas.js?v=20260915-mobile-budget";
import { createDefaultTransferFunction } from "./transfer-function.js?v=20260907-range-fix";

const shaderSource = `
struct Uniforms {
  mvp: mat4x4<f32>,
  clipMatrix: mat4x4<f32>,
  cameraTexture: vec4<f32>,
  level0BrickCount: vec4<f32>,
  atlasInfo: vec4<f32>,
  level0Size: vec4<f32>,
  cubeMin: vec4<f32>,
  cubeMax: vec4<f32>,
  lodInfo: vec4<f32>,
  dataInfo: vec4<f32>,
  volumeInfo: vec4<f32>,
};

@group(0) @binding(0) var<uniform> uniforms: Uniforms;

struct BrickRequestBits {
  words: array<atomic<u32>>,
};

struct BrickRequestList {
  count: atomic<u32>,
  ids: array<u32>,
};

@group(0) @binding(1) var<storage, read_write> brickRequestBits: BrickRequestBits;
@group(0) @binding(2) var<storage, read_write> brickRequestList: BrickRequestList;
@group(0) @binding(3) var volumeAtlas: texture_3d<f32>;
@group(0) @binding(4) var volumeSampler: sampler;
@group(0) @binding(5) var transferFunction: texture_2d<f32>;
@group(0) @binding(6) var transferSampler: sampler;

struct BrickMeta {
  values: array<u32>,
};

@group(0) @binding(7) var<storage, read> brickMeta: BrickMeta;

struct LevelData {
  bricksX: u32,
  bricksXTimesBricksY: u32,
  prevBricks: u32,
  pad0: u32,
  fractionalBrickLayout: vec4<f32>,
};

struct LevelTable {
  levels: array<LevelData>,
};

@group(0) @binding(8) var<storage, read> levelTable: LevelTable;
@group(0) @binding(9) var markerDepthTexture: texture_depth_2d;

const BI_MISSING: u32 = 0u;
const BI_CHILD_EMPTY: u32 = 1u;
const BI_EMPTY: u32 = 2u;
const BI_FLAG_COUNT: u32 = 3u;
const MAX_RAY_SAMPLE_COUNT: u32 = 2048u;
const MAX_BRICK_ITERATIONS: u32 = 4096u;
const RENDER_MODE_TF: u32 = 0u;
const RENDER_MODE_TF_LIGHTING: u32 = 1u;
const RENDER_MODE_ISO: u32 = 2u;

struct VertexIn {
  @location(0) position: vec3<f32>,
  @location(1) coord: vec3<f32>,
};

struct VertexOut {
  @builtin(position) position: vec4<f32>,
  @location(0) coord: vec3<f32>,
};

@vertex
fn vertexMain(input: VertexIn) -> VertexOut {
  var output: VertexOut;
  let clippedCoord = (uniforms.clipMatrix * vec4<f32>(input.coord - vec3<f32>(0.5), 1.0)).xyz + vec3<f32>(0.5);
  let halfExtent = abs(input.position);
  let clippedPosition = (clippedCoord * 2.0 - vec3<f32>(1.0)) * halfExtent;
  output.position = uniforms.mvp * vec4<f32>(clippedPosition, 1.0);
  output.coord = clippedCoord;
  return output;
}

fn cubeMin() -> vec3<f32> {
  return vec3<f32>(uniforms.cubeMin.x, uniforms.cubeMin.y, uniforms.cubeMin.z);
}

fn cubeMax() -> vec3<f32> {
  return vec3<f32>(uniforms.cubeMax.x, uniforms.cubeMax.y, uniforms.cubeMax.z);
}

fn axisEntryT(origin: f32, direction: f32, minBound: f32, maxBound: f32) -> f32 {
  if (abs(direction) < 0.000001) {
    return -10000000000.0;
  }
  return min((minBound - origin) / direction, (maxBound - origin) / direction);
}

fn axisExitT(origin: f32, direction: f32, minBound: f32, maxBound: f32) -> f32 {
  if (abs(direction) < 0.000001) {
    return 10000000000.0;
  }
  return max((minBound - origin) / direction, (maxBound - origin) / direction);
}

fn pointInsideCubeBounds(point: vec3<f32>) -> bool {
  return all(point >= cubeMin()) && all(point <= cubeMax());
}

fn computeEntryPoint(origin: vec3<f32>, exitPoint: vec3<f32>) -> vec3<f32> {
  if (pointInsideCubeBounds(origin)) {
    return origin;
  }

  let direction = exitPoint - origin;
  let tEntry = max(
    max(axisEntryT(origin.x, direction.x, uniforms.cubeMin.x, uniforms.cubeMax.x),
        axisEntryT(origin.y, direction.y, uniforms.cubeMin.y, uniforms.cubeMax.y)),
    axisEntryT(origin.z, direction.z, uniforms.cubeMin.z, uniforms.cubeMax.z)
  );
  let tExit = min(
    min(axisExitT(origin.x, direction.x, uniforms.cubeMin.x, uniforms.cubeMax.x),
        axisExitT(origin.y, direction.y, uniforms.cubeMin.y, uniforms.cubeMax.y)),
    axisExitT(origin.z, direction.z, uniforms.cubeMin.z, uniforms.cubeMax.z)
  );

  if (tEntry <= tExit && tExit >= 0.0) {
    return origin + direction * clamp(tEntry, 0.0, 1.0);
  }
  return origin;
}

fn reportBrickRequest(brickIndex: u32) {
  let wordIndex = brickIndex / 32u;
  if (wordIndex < arrayLength(&brickRequestBits.words)) {
    let bit = 1u << (brickIndex & 31u);
    let oldWord = atomicOr(&brickRequestBits.words[wordIndex], bit);
    if ((oldWord & bit) == 0u) {
      let slot = atomicAdd(&brickRequestList.count, 1u);
      if (slot < arrayLength(&brickRequestList.ids)) {
        brickRequestList.ids[slot] = brickIndex;
      }
    }
  }
}

fn effectiveBrickSize() -> f32 {
  return max(uniforms.atlasInfo.y - 2.0 * uniforms.atlasInfo.z, 1.0);
}

fn availableLevelCount() -> u32 {
  return max(arrayLength(&levelTable.levels), 1u);
}

fn clampedLOD(lod: u32) -> u32 {
  return min(lod, availableLevelCount() - 1u);
}

fn levelFractionalBrickLayout(lod: u32) -> vec3<f32> {
  return max(levelTable.levels[clampedLOD(lod)].fractionalBrickLayout.xyz, vec3<f32>(0.000001));
}

fn levelVoxelSize(lod: u32) -> vec3<f32> {
  return levelFractionalBrickLayout(lod) * effectiveBrickSize();
}

fn level0VoxelSize() -> vec3<f32> {
  return max(vec3<f32>(
    uniforms.level0Size.x,
    uniforms.level0Size.y,
    uniforms.level0Size.z
  ), vec3<f32>(1.0));
}

fn computeLOD(distance: f32) -> u32 {
  let levelCount = availableLevelCount();
  let lodFactor = max(uniforms.lodInfo.y, 0.0);
  let levelZeroError = max(uniforms.lodInfo.z, 0.000001);
  let ratio = max((lodFactor * max(distance, 0.0)) / levelZeroError, 1.0);
  return min(levelCount - 1u, u32(log2(ratio)));
}

fn brickCoordsAt(point: vec3<f32>, direction: vec3<f32>, lod: u32) -> vec3<u32> {
  let fractionalLayout = levelFractionalBrickLayout(lod);
  var scaledCoords = clamp(point, vec3<f32>(0.0), vec3<f32>(1.0)) * fractionalLayout;
  let nearestBoundary = round(scaledCoords);
  let boundaryDistance = abs(scaledCoords - nearestBoundary);

  if (boundaryDistance.x <= 0.00001 && direction.x < 0.0) {
    scaledCoords.x = nearestBoundary.x - 0.00001;
  }
  if (boundaryDistance.y <= 0.00001 && direction.y < 0.0) {
    scaledCoords.y = nearestBoundary.y - 0.00001;
  }
  if (boundaryDistance.z <= 0.00001 && direction.z < 0.0) {
    scaledCoords.z = nearestBoundary.z - 0.00001;
  }

  let maxCoords = max(vec3<u32>(
    u32(ceil(fractionalLayout.x)),
    u32(ceil(fractionalLayout.y)),
    u32(ceil(fractionalLayout.z))
  ), vec3<u32>(1u)) - vec3<u32>(1u);
  let brickPosition = max(scaledCoords, vec3<f32>(0.0));
  return min(vec3<u32>(
    u32(brickPosition.x),
    u32(brickPosition.y),
    u32(brickPosition.z)
  ), maxCoords);
}

fn brickIndexForCoords(coords: vec3<u32>, lod: u32) -> u32 {
  let level = levelTable.levels[clampedLOD(lod)];
  return level.prevBricks + coords.x + coords.y * level.bricksX + coords.z * level.bricksXTimesBricksY;
}

fn brickBoundsMin(brickCoords: vec3<u32>, lod: u32) -> vec3<f32> {
  return vec3<f32>(
    f32(brickCoords.x),
    f32(brickCoords.y),
    f32(brickCoords.z)
  ) / levelFractionalBrickLayout(lod);
}

fn brickBoundsMax(brickCoords: vec3<u32>, lod: u32) -> vec3<f32> {
  return vec3<f32>(
    f32(brickCoords.x + 1u),
    f32(brickCoords.y + 1u),
    f32(brickCoords.z + 1u)
  ) / levelFractionalBrickLayout(lod);
}

fn brickAxisExitT(origin: f32, direction: f32, minBound: f32, maxBound: f32) -> f32 {
  if (abs(direction) < 0.000001) {
    return 10000000000.0;
  }
  if (direction > 0.0) {
    return (maxBound - origin) / direction;
  }
  return (minBound - origin) / direction;
}

fn brickSegmentExitT(point: vec3<f32>, ray: vec3<f32>, minBound: vec3<f32>, maxBound: vec3<f32>) -> f32 {
  let tIntersect = vec3<f32>(
    brickAxisExitT(point.x, ray.x, minBound.x, maxBound.x),
    brickAxisExitT(point.y, ray.y, minBound.y, maxBound.y),
    brickAxisExitT(point.z, ray.z, minBound.z, maxBound.z)
  );
  return min(min(tIntersect.x, tIntersect.y), tIntersect.z);
}

fn brickInfoFor(brickIndex: u32) -> u32 {
  if (brickIndex >= arrayLength(&brickMeta.values)) {
    return BI_EMPTY;
  }
  return brickMeta.values[brickIndex];
}

struct BrickLookup {
  lod: u32,
  index: u32,
  info: u32,
  empty: bool,
  coords: vec3<u32>,
  minBound: vec3<f32>,
  maxBound: vec3<f32>,
};

fn lookupBrick(point: vec3<f32>, direction: vec3<f32>, requestedLOD: u32) -> BrickLookup {
  var result: BrickLookup;
  result.lod = clampedLOD(requestedLOD);
  result.coords = brickCoordsAt(point, direction, result.lod);
  result.index = brickIndexForCoords(result.coords, result.lod);
  result.info = brickInfoFor(result.index);
  result.empty = false;

  if (result.info == BI_MISSING) {
    reportBrickRequest(result.index);
    let startLOD = result.lod;
    var lastMissingIndex = result.index;
    for (var lowerLOD = result.lod + 1u; lowerLOD < availableLevelCount(); lowerLOD = lowerLOD + 1u) {
      let lowerCoords = brickCoordsAt(point, direction, lowerLOD);
      let lowerIndex = brickIndexForCoords(lowerCoords, lowerLOD);
      let lowerInfo = brickInfoFor(lowerIndex);
      if (lowerInfo != BI_MISSING) {
        result.lod = lowerLOD;
        result.coords = lowerCoords;
        result.index = lowerIndex;
        result.info = lowerInfo;
        break;
      }
      lastMissingIndex = lowerIndex;
    }
    if (startLOD < result.lod) {
      reportBrickRequest(lastMissingIndex);
    }
  }

  result.empty = result.info <= BI_EMPTY;
  if (result.empty && result.info != BI_MISSING) {
    for (var lowerLOD = result.lod + 1u; lowerLOD < availableLevelCount(); lowerLOD = lowerLOD + 1u) {
      let lowerCoords = brickCoordsAt(point, direction, lowerLOD);
      let lowerIndex = brickIndexForCoords(lowerCoords, lowerLOD);
      let lowerInfo = brickInfoFor(lowerIndex);
      if (lowerInfo == BI_CHILD_EMPTY) {
        result.lod = lowerLOD;
        result.coords = lowerCoords;
        result.index = lowerIndex;
        result.info = lowerInfo;
      } else {
        break;
      }
    }
  }

  result.minBound = max(brickBoundsMin(result.coords, result.lod), cubeMin());
  result.maxBound = min(brickBoundsMax(result.coords, result.lod), cubeMax());
  return result;
}

fn sampleAtlasBrick(brickIndex: u32, brickCoords: vec3<u32>, lod: u32, point: vec3<f32>) -> f32 {
  let brickInfo = brickInfoFor(brickIndex);
  if (brickInfo < BI_FLAG_COUNT) {
    return 0.0;
  }

  let slot = brickInfo - BI_FLAG_COUNT;
  let atlasAxis = max(u32(uniforms.atlasInfo.x), 1u);
  let brickSize = max(uniforms.atlasInfo.y, 1.0);
  let overlap = min(max(uniforms.atlasInfo.z, 0.0), brickSize * 0.25);
  let atlasSize = max(uniforms.atlasInfo.w, 1.0);
  let slotCoord = vec3<u32>(
    slot % atlasAxis,
    (slot / atlasAxis) % atlasAxis,
    slot / (atlasAxis * atlasAxis)
  );

  let levelSize = levelVoxelSize(lod);
  let clampedPoint = clamp(point, vec3<f32>(0.0), vec3<f32>(0.999999));
  let interiorSize = max(brickSize - 2.0 * overlap, 1.0);
  let brickStartVoxel = vec3<f32>(
    f32(brickCoords.x),
    f32(brickCoords.y),
    f32(brickCoords.z)
  ) * interiorSize;
  let localVoxel = clamp(overlap + clampedPoint * levelSize - brickStartVoxel, vec3<f32>(0.0), vec3<f32>(brickSize - 1.0));
  let atlasVoxel = vec3<f32>(
    f32(slotCoord.x),
    f32(slotCoord.y),
    f32(slotCoord.z)
  ) * brickSize + localVoxel;
  let atlasCoords = (atlasVoxel + vec3<f32>(0.5)) / atlasSize;
  return textureSampleLevel(volumeAtlas, volumeSampler, atlasCoords, 0.0).r;
}

fn safeNormalize(vector: vec3<f32>) -> vec3<f32> {
  let vectorLength = length(vector);
  if (vectorLength <= 0.000001) {
    return vec3<f32>(0.0, 0.0, 0.0);
  }
  return vector / vectorLength;
}

fn computeNormalForBrick(brickIndex: u32, brickCoords: vec3<u32>, lod: u32, point: vec3<f32>) -> vec3<f32> {
  let delta = vec3<f32>(1.0) / levelVoxelSize(lod);
  let xp = sampleAtlasBrick(brickIndex, brickCoords, lod, point + vec3<f32>(delta.x, 0.0, 0.0));
  let xm = sampleAtlasBrick(brickIndex, brickCoords, lod, point - vec3<f32>(delta.x, 0.0, 0.0));
  let yp = sampleAtlasBrick(brickIndex, brickCoords, lod, point + vec3<f32>(0.0, delta.y, 0.0));
  let ym = sampleAtlasBrick(brickIndex, brickCoords, lod, point - vec3<f32>(0.0, delta.y, 0.0));
  let zp = sampleAtlasBrick(brickIndex, brickCoords, lod, point + vec3<f32>(0.0, 0.0, delta.z));
  let zm = sampleAtlasBrick(brickIndex, brickCoords, lod, point - vec3<f32>(0.0, 0.0, delta.z));
  return safeNormalize(vec3<f32>(xp - xm, yp - ym, zp - zm));
}

fn refineIsosurfaceForBrick(
  brickIndex: u32,
  brickCoords: vec3<u32>,
  lod: u32,
  samplePoint: vec3<f32>,
  rayStep: vec3<f32>,
  isoValue: f32
) -> vec3<f32> {
  var stepVector = rayStep / 2.0;
  var refinedPoint = samplePoint - stepVector;
  for (var index = 0u; index < 5u; index = index + 1u) {
    stepVector = stepVector / 2.0;
    let value = sampleAtlasBrick(brickIndex, brickCoords, lod, refinedPoint);
    if (value >= isoValue) {
      refinedPoint = refinedPoint - stepVector;
    } else {
      refinedPoint = refinedPoint + stepVector;
    }
    if (abs(value - isoValue) < 0.001) {
      break;
    }
  }
  return refinedPoint;
}

fn lighting(samplePoint: vec3<f32>, normal: vec3<f32>, color: vec3<f32>) -> vec3<f32> {
  let ambientLight = vec3<f32>(0.1, 0.1, 0.1);
  let diffuseLight = vec3<f32>(0.5, 0.5, 0.5);
  let specularLight = vec3<f32>(0.8, 0.8, 0.8);
  let viewDir = safeNormalize(uniforms.cameraTexture.xyz - samplePoint);
  let lightDir = viewDir;
  let reflection = reflect(-lightDir, normal);
  let diffuse = max(abs(dot(normal, lightDir)), 0.0);
  let specular = pow(max(dot(viewDir, reflection), 0.0), 8.0);
  return clamp(
    color * ambientLight + color * diffuseLight * diffuse + specularLight * specular,
    vec3<f32>(0.0),
    vec3<f32>(1.0)
  );
}

fn markerOccludesPoint(point: vec3<f32>, markerDepth: f32) -> bool {
  if (markerDepth >= 0.999999) {
    return false;
  }
  let localPoint = (point * 2.0 - vec3<f32>(1.0)) * uniforms.volumeInfo.xyz;
  let clipPoint = uniforms.mvp * vec4<f32>(localPoint, 1.0);
  if (clipPoint.w <= 0.0) {
    return false;
  }
  return clipPoint.z / clipPoint.w >= markerDepth - 0.00001;
}

@fragment
fn fragmentMain(input: VertexOut) -> @location(0) vec4<f32> {
  let exitPoint = input.coord;
  let entryPoint = computeEntryPoint(uniforms.cameraTexture.xyz, exitPoint);
  let ray = exitPoint - entryPoint;
  let rayLength = length(ray);
  if (rayLength < 0.000001) {
    return vec4<f32>(0.0);
  }
  let entryDepth = length(uniforms.cameraTexture.xyz - entryPoint);
  let exitDepth = length(uniforms.cameraTexture.xyz - exitPoint);

  var accumulatedColor = vec3<f32>(0.0);
  var accumulatedAlpha = 0.0;
  let renderMode = u32(uniforms.dataInfo.y + 0.5);
  let isoValue = uniforms.dataInfo.z;
  let markerDepth = textureLoad(markerDepthTexture, vec2<i32>(input.position.xy), 0);

  var currentRayT = 0.0;
  for (var brickIteration = 0u; brickIteration < MAX_BRICK_ITERATIONS; brickIteration = brickIteration + 1u) {
    if (currentRayT >= 0.999999) {
      break;
    }

    let currentPos = entryPoint + ray * currentRayT;
    if (markerOccludesPoint(currentPos, markerDepth)) {
      break;
    }
    let currentDepth = mix(entryDepth, exitDepth, currentRayT);
    let brick = lookupBrick(currentPos, ray, computeLOD(currentDepth));
    let segmentT = min(
      max(brickSegmentExitT(currentPos, ray, brick.minBound, brick.maxBound), 0.0),
      1.0 - currentRayT
    );
    let nextRayT = min(max(currentRayT + segmentT, currentRayT + 0.000001), 1.0);

    if (!brick.empty && brick.info >= BI_FLAG_COUNT) {
      let segmentVoxelLength = length((ray * (nextRayT - currentRayT)) * levelVoxelSize(brick.lod));
      let segmentSampleCount = min(max(u32(ceil(segmentVoxelLength * 2.0)), 1u), MAX_RAY_SAMPLE_COUNT);
      let sampleStep = ray * ((nextRayT - currentRayT) / f32(segmentSampleCount));
      let sampleStepVoxelLength = segmentVoxelLength / f32(segmentSampleCount);
      let lodScale = f32(1u << brick.lod);
      let ocFactor = max(lodScale * 2.0 * sampleStepVoxelLength, 0.000001);

      for (var sampleIndex = 0u; sampleIndex < MAX_RAY_SAMPLE_COUNT; sampleIndex = sampleIndex + 1u) {
        if (sampleIndex >= segmentSampleCount) {
          break;
        }
        let localT = (f32(sampleIndex) + 0.5) / f32(segmentSampleCount);
        let sampleRayT = mix(currentRayT, nextRayT, localT);
        let samplePoint = entryPoint + ray * sampleRayT;
        if (markerOccludesPoint(samplePoint, markerDepth)) {
          break;
        }
        let scalar = sampleAtlasBrick(brick.index, brick.coords, brick.lod, samplePoint);

        if (renderMode == RENDER_MODE_ISO) {
          if (scalar >= isoValue) {
            let refinedPoint = refineIsosurfaceForBrick(brick.index, brick.coords, brick.lod, samplePoint, sampleStep, isoValue);
            let normal = computeNormalForBrick(brick.index, brick.coords, brick.lod, refinedPoint);
            return vec4<f32>(lighting(refinedPoint, normal, vec3<f32>(0.5, 0.5, 0.5)), 1.0);
          }
          continue;
        }

        let tf = textureSampleLevel(transferFunction, transferSampler, vec2<f32>(scalar * uniforms.dataInfo.x, 0.5), 0.0);
        let alpha = 1.0 - pow(1.0 - tf.a, ocFactor);
        var sampleColor = tf.rgb;
        if (renderMode == RENDER_MODE_TF_LIGHTING && alpha > 0.01) {
          let normal = computeNormalForBrick(brick.index, brick.coords, brick.lod, samplePoint);
          sampleColor = clamp(sampleColor + lighting(samplePoint, normal, sampleColor), vec3<f32>(0.0), vec3<f32>(1.0));
        }
        accumulatedColor = accumulatedColor + (1.0 - accumulatedAlpha) * sampleColor * alpha;
        accumulatedAlpha = accumulatedAlpha + (1.0 - accumulatedAlpha) * alpha;
        if (accumulatedAlpha > 0.99) {
          break;
        }
      }
    }

    if (accumulatedAlpha > 0.99) {
      break;
    }
    currentRayT = nextRayT;
  }

  return vec4<f32>(accumulatedColor, accumulatedAlpha);
}
`;

const markerShaderSource = `
struct MarkerUniforms {
  mvp: mat4x4<f32>,
  modelView: mat4x4<f32>,
};

@group(0) @binding(0) var<uniform> uniforms: MarkerUniforms;

struct MarkerVertexIn {
  @location(0) position: vec3<f32>,
  @location(1) normal: vec3<f32>,
  @location(2) centerRadius: vec4<f32>,
  @location(3) color: vec4<f32>,
};

struct MarkerVertexOut {
  @builtin(position) position: vec4<f32>,
  @location(0) normalView: vec3<f32>,
  @location(1) color: vec3<f32>,
};

@vertex
fn markerVertexMain(input: MarkerVertexIn) -> MarkerVertexOut {
  var output: MarkerVertexOut;
  let localPosition = input.centerRadius.xyz + input.position * input.centerRadius.w;
  output.position = uniforms.mvp * vec4<f32>(localPosition, 1.0);
  output.normalView = normalize((uniforms.modelView * vec4<f32>(input.normal, 0.0)).xyz);
  output.color = input.color.rgb;
  return output;
}

@fragment
fn markerFragmentMain(input: MarkerVertexOut) -> @location(0) vec4<f32> {
  let normal = normalize(input.normalView);
  let lightDirection = vec3<f32>(0.0, 0.0, 1.0);
  let diffuse = max(dot(normal, lightDirection), 0.0);
  let specular = pow(max(normal.z, 0.0), 24.0);
  let color = input.color * (0.28 + 0.72 * diffuse) + vec3<f32>(0.32) * specular;
  return vec4<f32>(clamp(color, vec3<f32>(0.0), vec3<f32>(1.0)), 1.0);
}
`;

const MAX_BRICK_REQUEST_LIST_IDS = 65536;
const BRICK_REQUEST_READBACK_INTERVAL = 1;
const UNIFORM_BUFFER_BYTE_LENGTH = 272;
const MARKER_UNIFORM_BUFFER_BYTE_LENGTH = 128;
const MARKER_INSTANCE_STRIDE = 32;
const LEVEL_DATA_STRIDE = 32;
const DEFAULT_SCREEN_SPACE_ERROR = 1.0;
const APPLE_MOBILE_RENDER_PIXEL_RATIO = 1.0;
const RENDER_MODES = new Map([
  ["tf", 0],
  ["tf-lighting", 1],
  ["iso", 2]
]);

export class CoordinateCubeRenderer {
  constructor(canvas) {
    this.canvas = canvas;
    this.device = null;
    this.context = null;
    this.format = null;
    this.pipeline = null;
    this.markerPipeline = null;
    this.uniformBuffer = null;
    this.markerUniformBuffer = null;
    this.markerBindGroup = null;
    this.bindGroup = null;
    this.brickAtlas = null;
    this.transferFunction = null;
    this.transferFunctionTexture = null;
    this.transferFunctionSampler = null;
    this.fallbackVolumeTexture = null;
    this.fallbackBrickMetaBuffer = null;
    this.fallbackLevelDataBuffer = null;
    this.levelDataBuffer = null;
    this.volumeSampler = null;
    this.brickRequestBitsetBuffer = null;
    this.brickRequestListBuffer = null;
    this.brickRequestReadbackBuffer = null;
    this.brickRequestBitsetClearData = new Uint32Array(1);
    this.brickRequestListClearData = new Uint32Array(2);
    this.brickRequestBitsetWordCount = 1;
    this.brickRequestListCapacity = 1;
    this.brickRequestListByteLength = 8;
    this.brickRequestReadbackInFlight = false;
    this.frameIndex = 0;
    this.vertexBuffer = null;
    this.indexBuffer = null;
    this.depthTexture = null;
    this.markerDepthTexture = null;
    this.depthWidth = 0;
    this.depthHeight = 0;
    this.indexCount = 0;
    this.markerVertexBuffer = null;
    this.markerIndexBuffer = null;
    this.markerInstanceBuffer = null;
    this.markerIndexCount = 0;
    this.markerInstanceCount = 0;
    this.markers = [];
    this.volumeHalfExtent = [0.68, 0.68, 0.68];
    this.level0BrickCount = [1, 1, 1];
    this.level0Size = [1, 1, 1];
    this.levelCount = 1;
    this.levelZeroWorldSpaceError = 1;
    this.screenSpaceError = DEFAULT_SCREEN_SPACE_ERROR;
    this.transferBias = 1;
    this.renderMode = RENDER_MODES.get("tf");
    this.normIsoValue = 0.1;
    this.isoRawValue = 0.1;
    this.isoValue = 0.1;
    this.dataRange = [0, 1];
    this.valueRange = [0, 1];
    this.clipMin = [0, 0, 0];
    this.clipMax = [1, 1, 1];
    this.totalBrickCount = 1;
    this.lastPointer = null;
    this.activePointers = new Map();
    this.pinchGesture = null;
    this.dragStartVector = null;
    this.dragStartOrientation = null;
    this.hasScene = false;
    this.statusCallback = null;
    this.statusReporting = true;
    this.profilingEnabled = false;
    this.persistentBrickCacheEnabled = true;
    this.profile = createRendererProfile();
    this.animationFrame = 0;
    this.needsRender = false;
    this.readbackSkippedWhileInFlight = false;
    this.resizeObserver = null;
    this.pendingManifest = null;
    this.ready = false;
    this.resetView();
  }

  setStatusReporting(enabled) {
    this.statusReporting = enabled;
  }

  setProfiling(enabled) {
    this.profilingEnabled = enabled;
    this.profile = createRendererProfile();
    this.brickAtlas?.setProfiling(enabled);
  }

  setPersistentBrickCacheEnabled(enabled) {
    this.persistentBrickCacheEnabled = enabled;
    this.brickAtlas?.setPersistentCacheEnabled(enabled);
  }

  clearPersistentBrickCache() {
    return this.brickAtlas?.clearPersistentCache() ?? Promise.resolve();
  }

  setMarkers(markers) {
    this.markers = Array.isArray(markers) ? markers : [];
    this.uploadMarkerInstances();
    this.drawNow();
  }

  profileSnapshot() {
    const frameCount = Math.max(1, this.profile.frames);
    const readbacks = Math.max(1, this.profile.readbacks);
    const atlas = this.brickAtlas?.profileSnapshot() ?? null;
    return {
      renderer: {
        frames: this.profile.frames,
        drawCpuMs: this.profile.drawCpuMs,
        avgDrawCpuMs: this.profile.drawCpuMs / frameCount,
        readbacks: this.profile.readbacks,
        readbackMapMs: this.profile.readbackMapMs,
        readbackProcessMs: this.profile.readbackProcessMs,
        avgReadbackMapMs: this.profile.readbackMapMs / readbacks,
        avgReadbackProcessMs: this.profile.readbackProcessMs / readbacks,
        requestedBricks: this.profile.requestedBricks,
        avgRequestedBricks: this.profile.requestedBricks / readbacks,
        readbackOverflows: this.profile.readbackOverflows,
        skippedReadbacks: this.profile.skippedReadbacks
      },
      atlas
    };
  }

  profileSummaryText() {
    const snapshot = this.profileSnapshot();
    const atlas = snapshot.atlas;
    if (!atlas) {
      return "Profile: no atlas";
    }
    return [
      `Profile: ${atlas.loads} bricks`,
      `server ${atlas.serverBricks ?? 0} bricks / ${(atlas.fetchHeaderMs + atlas.fetchBodyMs).toFixed(0)} ms`,
      `cache ${atlas.cacheHits ?? 0} hits`,
      `lz4 ${atlas.lz4DecodeMs.toFixed(0)} ms`,
      `prep ${atlas.uploadPrepareMs.toFixed(0)} ms`,
      `upload ${atlas.uploadSubmitMs.toFixed(0)} ms`,
      `draw avg ${snapshot.renderer.avgDrawCpuMs.toFixed(2)} ms`
    ].join(" · ");
  }

  reportStatus(message) {
    this.statusCallback?.(message);
  }

  async initialize(statusCallback) {
    this.statusCallback = statusCallback;
    if (!navigator.gpu) {
      if (isAppleMobileDevice()) {
        throw new Error("WebGPU requires iOS/iPadOS 26 or newer on Apple mobile devices.");
      }
      throw new Error("WebGPU is not available in this browser.");
    }

    const adapter = await navigator.gpu.requestAdapter();
    if (!adapter) {
      if (isAppleMobileDevice()) {
        throw new Error("WebGPU requires iOS/iPadOS 26 or newer on Apple mobile devices.");
      }
      throw new Error("No WebGPU adapter is available.");
    }

    const requiredLimits = preferredDeviceLimits(adapter.limits);
    this.device = await adapter.requestDevice({ requiredLimits });
    this.reportStatus(webGPULimitSummary("WebGPU limits", this.device.limits));
    console.info("BorgVR WebGPU limits", {
      adapter: limitSnapshot(adapter.limits),
      requested: requiredLimits,
      device: limitSnapshot(this.device.limits)
    });
    this.device.addEventListener("uncapturederror", (event) => {
      this.reportStatus(`WebGPU error: ${event.error.message}`);
    });
    this.brickAtlas = new BrickAtlas(this.device, (message) => {
      if (this.statusReporting) {
        this.reportStatus(message);
      }
    }, () => {
      this.requestRender();
    });
    this.brickAtlas.setProfiling(this.profilingEnabled);
    this.brickAtlas.setPersistentCacheEnabled(this.persistentBrickCacheEnabled);
    this.context = this.canvas.getContext("webgpu");
    this.format = navigator.gpu.getPreferredCanvasFormat();
    this.configureContext();

    await this.createPipeline();
    this.installInteraction();
    this.installResizeObserver();
    this.resize();
    this.requestRender();
    this.ready = true;
    this.reportStatus("WebGPU ready. Select a dataset to start rendering.");
    if (this.pendingManifest) {
      const manifest = this.pendingManifest;
      this.pendingManifest = null;
      this.setDataset(manifest);
    }
  }

  setDataset(manifest) {
    if (!this.device) {
      this.pendingManifest = manifest;
      return;
    }

    manifest = normalizeManifestForRenderer(manifest);
    const physicalSize = manifest.volume.size.map((value, index) => value * manifest.volume.aspect[index]);
    const maxSize = Math.max(...physicalSize);
    const extent = physicalSize.map((value) => value / maxSize);
    this.resetView();
    this.level0BrickCount = manifest.levels?.[0]?.brickCount ?? [1, 1, 1];
    this.level0Size = manifest.levels?.[0]?.size ?? manifest.volume?.size ?? [1, 1, 1];
    this.levelCount = Math.max(1, manifest.levels?.length ?? 1);
    this.levelZeroWorldSpaceError = Math.max(
      (manifest.volume.aspect?.[0] ?? 1) / Math.max(1, manifest.volume.size?.[0] ?? 1),
      (manifest.volume.aspect?.[1] ?? 1) / Math.max(1, manifest.volume.size?.[1] ?? 1),
      (manifest.volume.aspect?.[2] ?? 1) / Math.max(1, manifest.volume.size?.[2] ?? 1)
    );
    const byteRangeMax = (2 ** (8 * (manifest.volume?.bytesPerComponent ?? 1))) - 1;
    this.dataRange = manifest.volume?.dataRange ?? [0, byteRangeMax];
    this.valueRange = manifest.volume?.valueRange ?? this.dataRange;
    const dataRangeMax = this.dataRange[1] ?? byteRangeMax;
    const valueRangeMax = this.valueRange[1] ?? dataRangeMax;
    this.transferBias = dataRangeMax / Math.max(1, valueRangeMax);
    this.updateIsoValue();
    this.totalBrickCount = manifest.bricks?.length ?? this.level0BrickCount[0] * this.level0BrickCount[1] * this.level0BrickCount[2];
    this.createLevelDataBuffer(manifest);
    this.createBrickRequestBuffers(this.totalBrickCount);
    this.brickAtlas?.reset(manifest, this.transferFunction, {
      renderMode: this.renderMode,
      isoRawValue: this.isoRawValue
    });
    this.rebuildBindGroup();
    this.frameIndex = 0;
    this.createCubeGeometry(extent);
    this.hasScene = true;
    this.drawNow();
    this.reportStatus(`Rendering ${manifest.name} · aspect ${extent.map((value) => value.toFixed(3)).join(" x ")}`);
  }

  setRenderMode(modeName) {
    const mode = RENDER_MODES.get(modeName);
    if (mode === undefined || this.renderMode === mode) {
      return;
    }
    this.renderMode = mode;
    this.reclassifyCurrentDataset();
    this.drawNow();
    this.reportStatus(`Render mode: ${modeName}`);
  }

  setIsoValue(value) {
    const nextValue = clamp(value, 0, 1);
    if (Math.abs(this.normIsoValue - nextValue) < 0.000001) {
      return;
    }
    this.normIsoValue = nextValue;
    this.updateIsoValue();
    if (this.renderMode === RENDER_MODES.get("iso")) {
      this.reclassifyCurrentDataset();
    }
    this.drawNow();
  }

  updateIsoValue() {
    const dataRangeMax = Math.max(1, this.dataRange?.[1] ?? 1);
    const valueRangeMax = this.valueRange?.[1] ?? dataRangeMax;
    this.isoRawValue = this.normIsoValue * valueRangeMax;
    this.isoValue = clamp(this.isoRawValue / dataRangeMax, 0, 1);
  }

  getNormalizedIsoValue() {
    return this.normIsoValue;
  }

  setTransferFunctionSmoothStep({ start, shift, channels }) {
    if (!this.transferFunction || !this.transferFunctionTexture) {
      return;
    }
    this.transferFunction.setSmoothStep(
      clamp(start, 0, 1),
      Math.max(0.001, shift),
      channels
    );
    this.updateTransferFunctionTexture();
    if (this.renderMode !== RENDER_MODES.get("iso")) {
      this.reclassifyCurrentDataset();
    }
    this.drawNow();
  }

  paintTransferFunction(previousPoint, point, channels) {
    if (!this.transferFunction || !this.transferFunctionTexture) {
      return;
    }
    this.transferFunction.paintLine(
      previousPoint.x,
      previousPoint.y,
      point.x,
      point.y,
      channels,
      1
    );
    this.finishTransferFunctionEdit();
  }

  resetTransferFunction() {
    if (!this.transferFunction || !this.transferFunctionTexture) {
      return;
    }
    this.transferFunction.reset();
    this.finishTransferFunctionEdit();
  }

  getTransferFunctionData() {
    return this.transferFunction?.data ?? new Uint8Array(0);
  }

  serializeTransferFunction() {
    if (!this.transferFunction) {
      return new ArrayBuffer(0);
    }
    return this.transferFunction.serializeNative();
  }

  loadTransferFunction(buffer) {
    if (!this.transferFunction || !this.device) {
      return;
    }
    this.transferFunction.loadNative(buffer);
    this.recreateTransferFunctionTexture();
    this.finishTransferFunctionEdit();
  }

  finishTransferFunctionEdit() {
    this.updateTransferFunctionTexture();
    if (this.renderMode !== RENDER_MODES.get("iso")) {
      this.reclassifyCurrentDataset();
    }
    this.drawNow();
  }

  setClipBound(axis, bound, value) {
    if (axis < 0 || axis > 2) {
      return;
    }
    const clampedValue = clamp(value, 0, 1);
    if (bound === "min") {
      this.clipMin[axis] = Math.min(clampedValue, this.clipMax[axis] - 0.001);
    } else if (bound === "max") {
      this.clipMax[axis] = Math.max(clampedValue, this.clipMin[axis] + 0.001);
    }
    this.drawNow();
  }

  resetClipping() {
    this.clipMin = [0, 0, 0];
    this.clipMax = [1, 1, 1];
    this.drawNow();
  }

  reclassifyCurrentDataset() {
    if (!this.hasScene || !this.brickAtlas?.manifest) {
      return;
    }
    this.brickAtlas.reclassify(this.transferFunction, {
      renderMode: this.renderMode,
      isoRawValue: this.isoRawValue
    });
  }

  resetView() {
    this.orientation = normalizeQuaternion(multiplyQuaternions(
      quaternionFromAxisAngle([1, 0, 0], -0.35),
      quaternionFromAxisAngle([0, 1, 0], 0.65)
    ));
    this.panX = 0;
    this.panY = 0;
    this.distance = 3.2;
  }

  resize() {
    const rect = this.canvas.getBoundingClientRect();
    const scale = renderPixelRatio();
    const width = Math.max(1, Math.round(rect.width * scale));
    const height = Math.max(1, Math.round(rect.height * scale));
    if (
      this.canvas.width !== width ||
      this.canvas.height !== height ||
      this.depthWidth !== width ||
      this.depthHeight !== height ||
      !this.depthTexture ||
      !this.markerDepthTexture
    ) {
      this.canvas.width = width;
      this.canvas.height = height;
      this.configureContext();
      this.depthTexture?.destroy();
      this.markerDepthTexture?.destroy();
      this.depthTexture = this.device?.createTexture({
        size: [width, height],
        format: "depth24plus",
        usage: GPUTextureUsage.RENDER_ATTACHMENT
      }) ?? null;
      this.markerDepthTexture = this.device?.createTexture({
        size: [width, height],
        format: "depth32float",
        usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING
      }) ?? null;
      this.depthWidth = this.depthTexture ? width : 0;
      this.depthHeight = this.depthTexture ? height : 0;
      this.rebuildBindGroup();
      this.reportStatus(this.hasScene
        ? `Rendering resized canvas · ${width} x ${height}`
        : `WebGPU canvas ready · ${width} x ${height}`);
    }
  }

  recreateTransferFunctionTexture() {
    if (!this.transferFunction || !this.device) {
      return;
    }
    this.transferFunctionTexture?.destroy();
    this.transferFunctionTexture = this.device.createTexture({
      size: [this.transferFunction.width, 1, 1],
      format: "rgba8unorm",
      usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST
    });
    this.rebuildBindGroup();
  }

  configureContext() {
    if (!this.context || !this.device || !this.format) {
      return;
    }
    this.context.configure({
      device: this.device,
      format: this.format,
      usage: GPUTextureUsage.RENDER_ATTACHMENT,
      alphaMode: "opaque"
    });
  }

  async createPipeline() {
    const shaderModule = this.device.createShaderModule({
      label: "BorgVR WebGPU volume shader",
      code: shaderSource
    });
    const compilationInfo = await shaderModule.getCompilationInfo();
    const shaderMessages = compilationInfo.messages.map((message) => {
      const location = message.lineNum ? `${message.lineNum}:${message.linePos}` : "unknown";
      return `${message.type.toUpperCase()} ${location} ${message.message}`;
    });
    if (shaderMessages.length > 0) {
      this.reportStatus(shaderMessages.join("\n"));
    }
    const shaderErrors = compilationInfo.messages.filter((message) => message.type === "error");
    if (shaderErrors.length > 0) {
      throw new Error(`Shader compilation failed:\n${shaderMessages.join("\n")}`);
    }
    this.createTextureResources();
    this.uniformBuffer = this.device.createBuffer({
      size: UNIFORM_BUFFER_BYTE_LENGTH,
      usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST
    });

    this.pipeline = await this.device.createRenderPipelineAsync({
      layout: "auto",
      vertex: {
        module: shaderModule,
        entryPoint: "vertexMain",
        buffers: [{
          arrayStride: 24,
          attributes: [
            { shaderLocation: 0, offset: 0, format: "float32x3" },
            { shaderLocation: 1, offset: 12, format: "float32x3" }
          ]
        }]
      },
      fragment: {
        module: shaderModule,
        entryPoint: "fragmentMain",
        targets: [{
          format: this.format,
          blend: {
            color: {
              operation: "add",
              srcFactor: "one",
              dstFactor: "one-minus-src-alpha"
            },
            alpha: {
              operation: "add",
              srcFactor: "one",
              dstFactor: "one-minus-src-alpha"
            }
          }
        }]
      },
      primitive: {
        topology: "triangle-list",
        cullMode: "front"
      },
      depthStencil: {
        depthWriteEnabled: true,
        depthCompare: "less",
        format: "depth24plus"
      }
    });

    await this.createMarkerPipeline();

    this.createBrickRequestBuffers(this.totalBrickCount);
  }

  async createMarkerPipeline() {
    const shaderModule = this.device.createShaderModule({
      label: "BorgVR WebGPU marker shader",
      code: markerShaderSource
    });
    const compilationInfo = await shaderModule.getCompilationInfo();
    const shaderErrors = compilationInfo.messages.filter((message) => message.type === "error");
    if (shaderErrors.length > 0) {
      throw new Error(`Marker shader compilation failed:\n${shaderErrors.map((message) => message.message).join("\n")}`);
    }

    this.markerUniformBuffer = this.device.createBuffer({
      size: MARKER_UNIFORM_BUFFER_BYTE_LENGTH,
      usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST
    });
    this.markerPipeline = await this.device.createRenderPipelineAsync({
      layout: "auto",
      vertex: {
        module: shaderModule,
        entryPoint: "markerVertexMain",
        buffers: [
          {
            arrayStride: 24,
            attributes: [
              { shaderLocation: 0, offset: 0, format: "float32x3" },
              { shaderLocation: 1, offset: 12, format: "float32x3" }
            ]
          },
          {
            arrayStride: MARKER_INSTANCE_STRIDE,
            stepMode: "instance",
            attributes: [
              { shaderLocation: 2, offset: 0, format: "float32x4" },
              { shaderLocation: 3, offset: 16, format: "float32x4" }
            ]
          }
        ]
      },
      fragment: {
        module: shaderModule,
        entryPoint: "markerFragmentMain",
        targets: [{ format: this.format }]
      },
      primitive: {
        topology: "triangle-list",
        cullMode: "back"
      },
      depthStencil: {
        depthWriteEnabled: true,
        depthCompare: "less",
        format: "depth32float"
      }
    });
    this.markerBindGroup = this.device.createBindGroup({
      layout: this.markerPipeline.getBindGroupLayout(0),
      entries: [{ binding: 0, resource: { buffer: this.markerUniformBuffer } }]
    });
    this.createMarkerGeometry();
    this.uploadMarkerInstances();
  }

  createTextureResources() {
    this.transferFunction = createDefaultTransferFunction();
    this.transferFunctionSampler = this.device.createSampler({
      addressModeU: "clamp-to-edge",
      addressModeV: "clamp-to-edge",
      magFilter: "linear",
      minFilter: "linear"
    });
    this.volumeSampler = this.device.createSampler({
      addressModeU: "clamp-to-edge",
      addressModeV: "clamp-to-edge",
      addressModeW: "clamp-to-edge",
      magFilter: "linear",
      minFilter: "linear"
    });
    this.fallbackVolumeTexture = this.device.createTexture({
      size: [1, 1, 1],
      dimension: "3d",
      format: "r16float",
      usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST
    });
    this.fallbackBrickMetaBuffer = this.device.createBuffer({
      size: Uint32Array.BYTES_PER_ELEMENT,
      usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST
    });
    this.device.queue.writeBuffer(this.fallbackBrickMetaBuffer, 0, new Uint32Array([0]));
    this.fallbackLevelDataBuffer = this.device.createBuffer({
      size: LEVEL_DATA_STRIDE,
      usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST
    });
    this.device.queue.writeBuffer(this.fallbackLevelDataBuffer, 0, createLevelDataArrayBuffer({
      volumeSize: [1, 1, 1],
      brickSize: 1,
      overlap: 0,
      levels: [{ level: 0, brickCount: [1, 1, 1], firstBrick: 0, size: [1, 1, 1] }]
    }));
    this.recreateTransferFunctionTexture();
    this.updateTransferFunctionTexture();
  }

  updateTransferFunctionTexture() {
    if (!this.transferFunction || !this.transferFunctionTexture) {
      return;
    }
    this.device.queue.writeTexture(
      { texture: this.transferFunctionTexture },
      this.transferFunction.data,
      { bytesPerRow: this.transferFunction.width * 4, rowsPerImage: 1 },
      [this.transferFunction.width, 1, 1]
    );
  }

  createLevelDataBuffer(manifest) {
    if (!this.device) {
      return;
    }

    this.levelDataBuffer?.destroy();
    const bufferData = createLevelDataArrayBuffer({
      volumeSize: manifest.volume?.size ?? [1, 1, 1],
      brickSize: manifest.bricking?.brickSize ?? 1,
      overlap: manifest.bricking?.overlap ?? 0,
      levels: manifest.levels ?? []
    });
    this.levelDataBuffer = this.device.createBuffer({
      size: bufferData.byteLength,
      usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST
    });
    this.device.queue.writeBuffer(this.levelDataBuffer, 0, bufferData);
  }

  createBrickRequestBuffers(totalBrickCount) {
    if (!this.device || !this.pipeline) {
      return;
    }

    const bitsetWordCount = Math.max(1, Math.ceil(Math.max(1, totalBrickCount) / 32));
    const maxStorageBufferBindingSize = this.device.limits.maxStorageBufferBindingSize ?? this.device.limits.maxBufferSize;
    const maxListCapacityByLimit = Math.max(1, Math.floor(maxStorageBufferBindingSize / Uint32Array.BYTES_PER_ELEMENT) - 1);
    const listCapacity = Math.max(1, Math.min(MAX_BRICK_REQUEST_LIST_IDS, Math.max(1, totalBrickCount), maxListCapacityByLimit));
    const bitsetByteLength = bitsetWordCount * Uint32Array.BYTES_PER_ELEMENT;
    const listByteLength = (listCapacity + 1) * Uint32Array.BYTES_PER_ELEMENT;
    if (bitsetByteLength > maxStorageBufferBindingSize) {
      throw new Error(`Brick request bitset needs ${formatMiB(bitsetByteLength)}, but WebGPU only allows ${formatMiB(maxStorageBufferBindingSize)} storage-buffer bindings.`);
    }
    if (listCapacity < Math.min(MAX_BRICK_REQUEST_LIST_IDS, Math.max(1, totalBrickCount))) {
      this.reportStatus(`Brick request readback list capped at ${listCapacity} entries by WebGPU storage-buffer limit ${formatMiB(maxStorageBufferBindingSize)}.`);
    }

    this.brickRequestBitsetBuffer?.destroy();
    this.brickRequestListBuffer?.destroy();
    this.brickRequestReadbackBuffer?.destroy();

    this.brickRequestBitsetBuffer = this.device.createBuffer({
      size: bitsetByteLength,
      usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST
    });
    this.brickRequestListBuffer = this.device.createBuffer({
      size: listByteLength,
      usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC | GPUBufferUsage.COPY_DST
    });
    this.brickRequestReadbackBuffer = this.device.createBuffer({
      size: listByteLength,
      usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST
    });
    this.brickRequestBitsetClearData = new Uint32Array(bitsetWordCount);
    this.brickRequestListClearData = new Uint32Array(listCapacity + 1);
    this.brickRequestBitsetWordCount = bitsetWordCount;
    this.brickRequestListCapacity = listCapacity;
    this.brickRequestListByteLength = listByteLength;
    this.brickRequestReadbackInFlight = false;

    this.rebuildBindGroup();
  }

  rebuildBindGroup() {
    if (!this.device ||
        !this.pipeline ||
        !this.uniformBuffer ||
        !this.brickRequestBitsetBuffer ||
        !this.brickRequestListBuffer ||
        !this.transferFunctionTexture ||
        !this.transferFunctionSampler ||
        !this.volumeSampler ||
        !this.fallbackVolumeTexture ||
        !this.fallbackBrickMetaBuffer ||
        !this.fallbackLevelDataBuffer ||
        !this.markerDepthTexture) {
      return;
    }

    const volumeTexture = this.brickAtlas?.texture ?? this.fallbackVolumeTexture;
    const brickMetaBuffer = this.brickAtlas?.brickMetaBuffer ?? this.fallbackBrickMetaBuffer;
    const levelDataBuffer = this.levelDataBuffer ?? this.fallbackLevelDataBuffer;
    this.bindGroup = this.device.createBindGroup({
      layout: this.pipeline.getBindGroupLayout(0),
      entries: [
        { binding: 0, resource: { buffer: this.uniformBuffer } },
        { binding: 1, resource: { buffer: this.brickRequestBitsetBuffer } },
        { binding: 2, resource: { buffer: this.brickRequestListBuffer } },
        { binding: 3, resource: volumeTexture.createView() },
        { binding: 4, resource: this.volumeSampler },
        { binding: 5, resource: this.transferFunctionTexture.createView() },
        { binding: 6, resource: this.transferFunctionSampler },
        { binding: 7, resource: { buffer: brickMetaBuffer } },
        { binding: 8, resource: { buffer: levelDataBuffer } },
        { binding: 9, resource: this.markerDepthTexture.createView() }
      ]
    });
  }

  createCubeGeometry(extent) {
    const [sx, sy, sz] = extent.map((value) => value * 0.68);
    this.volumeHalfExtent = [sx, sy, sz];
    const x0 = -sx;
    const x1 = sx;
    const y0 = -sy;
    const y1 = sy;
    const z0 = -sz;
    const z1 = sz;
    const vertexData = new Float32Array([
      x0, y0, z0, 0, 0, 0,
      x1, y0, z0, 1, 0, 0,
      x1, y1, z0, 1, 1, 0,
      x0, y1, z0, 0, 1, 0,
      x0, y0, z1, 0, 0, 1,
      x1, y0, z1, 1, 0, 1,
      x1, y1, z1, 1, 1, 1,
      x0, y1, z1, 0, 1, 1
    ]);

    const indexData = new Uint16Array([
      0, 2, 1, 0, 3, 2,
      4, 5, 6, 4, 6, 7,
      0, 1, 5, 0, 5, 4,
      3, 6, 2, 3, 7, 6,
      1, 2, 6, 1, 6, 5,
      0, 4, 7, 0, 7, 3
    ]);

    this.vertexBuffer?.destroy();
    this.indexBuffer?.destroy();
    this.vertexBuffer = this.device.createBuffer({
      size: vertexData.byteLength,
      usage: GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST
    });
    this.indexBuffer = this.device.createBuffer({
      size: indexData.byteLength,
      usage: GPUBufferUsage.INDEX | GPUBufferUsage.COPY_DST
    });
    this.device.queue.writeBuffer(this.vertexBuffer, 0, vertexData);
    this.device.queue.writeBuffer(this.indexBuffer, 0, indexData);
    this.indexCount = indexData.length;
    this.uploadMarkerInstances();
  }

  createMarkerGeometry() {
    if (!this.device) {
      return;
    }
    const latitudeSegments = 20;
    const longitudeSegments = 32;
    const vertices = [];
    const indices = [];
    for (let latitude = 0; latitude <= latitudeSegments; latitude += 1) {
      const theta = latitude * Math.PI / latitudeSegments;
      const radial = Math.sin(theta);
      const y = Math.cos(theta);
      for (let longitude = 0; longitude <= longitudeSegments; longitude += 1) {
        const phi = longitude * 2 * Math.PI / longitudeSegments;
        const x = radial * Math.cos(phi);
        const z = radial * Math.sin(phi);
        vertices.push(x, y, z, x, y, z);
      }
    }
    const rowLength = longitudeSegments + 1;
    for (let latitude = 0; latitude < latitudeSegments; latitude += 1) {
      for (let longitude = 0; longitude < longitudeSegments; longitude += 1) {
        const topLeft = latitude * rowLength + longitude;
        const bottomLeft = topLeft + rowLength;
        indices.push(topLeft, topLeft + 1, bottomLeft);
        indices.push(bottomLeft, topLeft + 1, bottomLeft + 1);
      }
    }

    const vertexData = new Float32Array(vertices);
    const indexData = new Uint16Array(indices);
    this.markerVertexBuffer?.destroy();
    this.markerIndexBuffer?.destroy();
    this.markerVertexBuffer = this.device.createBuffer({
      size: vertexData.byteLength,
      usage: GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST
    });
    this.markerIndexBuffer = this.device.createBuffer({
      size: indexData.byteLength,
      usage: GPUBufferUsage.INDEX | GPUBufferUsage.COPY_DST
    });
    this.device.queue.writeBuffer(this.markerVertexBuffer, 0, vertexData);
    this.device.queue.writeBuffer(this.markerIndexBuffer, 0, indexData);
    this.markerIndexCount = indexData.length;
  }

  uploadMarkerInstances() {
    if (!this.device) {
      return;
    }
    const markerScale = 1.36;
    const primitives = this.markers.flatMap((marker) =>
      (Array.isArray(marker.points) ? marker.points : []).map((point) => ({
        position: point.position,
        radius: point.radius,
        color: marker.color
      }))
    );
    const instanceData = new Float32Array(primitives.length * 8);
    primitives.forEach((marker, index) => {
      const offset = index * 8;
      instanceData[offset] = (marker.position[0] - 0.5) * 2 * this.volumeHalfExtent[0];
      instanceData[offset + 1] = (marker.position[1] - 0.5) * 2 * this.volumeHalfExtent[1];
      instanceData[offset + 2] = (marker.position[2] - 0.5) * 2 * this.volumeHalfExtent[2];
      instanceData[offset + 3] = marker.radius * markerScale;
      instanceData.set(marker.color, offset + 4);
    });

    this.markerInstanceBuffer?.destroy();
    this.markerInstanceBuffer = this.device.createBuffer({
      size: Math.max(MARKER_INSTANCE_STRIDE, instanceData.byteLength),
      usage: GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST
    });
    if (instanceData.byteLength > 0) {
      this.device.queue.writeBuffer(this.markerInstanceBuffer, 0, instanceData);
    }
    this.markerInstanceCount = primitives.length;
  }

  installInteraction() {
    this.canvas.addEventListener("pointerdown", (event) => {
      event.preventDefault();
      this.canvas.setPointerCapture(event.pointerId);
      this.activePointers.set(event.pointerId, {
        x: event.clientX,
        y: event.clientY
      });
      if (this.activePointers.size >= 2) {
        this.beginPinchGesture();
        return;
      }
      this.lastPointer = {
        x: event.clientX,
        y: event.clientY,
        mode: event.shiftKey || event.button === 2 ? "pan" : "rotate"
      };
      if (this.lastPointer.mode === "rotate") {
        this.dragStartVector = this.projectPointerToArcball(event.clientX, event.clientY);
        this.dragStartOrientation = this.orientation;
      }
    });

    this.canvas.addEventListener("pointermove", (event) => {
      if (this.activePointers.has(event.pointerId)) {
        this.activePointers.set(event.pointerId, {
          x: event.clientX,
          y: event.clientY
        });
      }
      if (this.pinchGesture && this.activePointers.size >= 2) {
        event.preventDefault();
        this.updatePinchGesture();
        this.requestRender();
        return;
      }
      if (!this.lastPointer) {
        return;
      }
      event.preventDefault();
      const dx = event.clientX - this.lastPointer.x;
      const dy = event.clientY - this.lastPointer.y;
      this.lastPointer.x = event.clientX;
      this.lastPointer.y = event.clientY;

      if (this.lastPointer.mode === "pan") {
        this.panX += dx * 0.003;
        this.panY -= dy * 0.003;
      } else {
        this.applyArcballRotation(event.clientX, event.clientY);
      }
      this.requestRender();
    });

    this.canvas.addEventListener("pointerup", (event) => {
      this.endPointerInteraction(event.pointerId);
    });
    this.canvas.addEventListener("pointercancel", (event) => {
      this.endPointerInteraction(event.pointerId);
    });
    this.canvas.addEventListener("lostpointercapture", (event) => {
      this.endPointerInteraction(event.pointerId);
    });
    this.canvas.addEventListener("contextmenu", (event) => event.preventDefault());
    this.canvas.addEventListener("wheel", (event) => {
      event.preventDefault();
      this.distance *= Math.exp(event.deltaY * 0.001);
      this.distance = Math.max(0.2, Math.min(500.0, this.distance));
      this.requestRender();
    }, { passive: false });
  }

  beginPinchGesture() {
    const points = Array.from(this.activePointers.values()).slice(0, 2);
    if (points.length < 2) {
      return;
    }
    const center = midpoint(points[0], points[1]);
    this.pinchGesture = {
      distance: Math.max(1, pointDistance(points[0], points[1])),
      centerX: center.x,
      centerY: center.y,
      viewDistance: this.distance
    };
    this.lastPointer = null;
    this.dragStartVector = null;
    this.dragStartOrientation = null;
  }

  updatePinchGesture() {
    const points = Array.from(this.activePointers.values()).slice(0, 2);
    if (points.length < 2 || !this.pinchGesture) {
      return;
    }
    const center = midpoint(points[0], points[1]);
    const nextDistance = Math.max(1, pointDistance(points[0], points[1]));
    const scale = this.pinchGesture.distance / nextDistance;
    const dx = center.x - this.pinchGesture.centerX;
    const dy = center.y - this.pinchGesture.centerY;
    this.distance = clamp(this.pinchGesture.viewDistance * scale, 0.2, 500.0);
    this.panX += dx * 0.003;
    this.panY -= dy * 0.003;
    this.pinchGesture.distance = nextDistance;
    this.pinchGesture.centerX = center.x;
    this.pinchGesture.centerY = center.y;
    this.pinchGesture.viewDistance = this.distance;
  }

  endPointerInteraction(pointerId) {
    this.activePointers.delete(pointerId);
    if (this.activePointers.size >= 2) {
      this.beginPinchGesture();
      return;
    }
    this.pinchGesture = null;
    this.lastPointer = null;
    this.dragStartVector = null;
    this.dragStartOrientation = null;
  }

  installResizeObserver() {
    window.addEventListener("resize", () => this.requestRender());
    if (typeof ResizeObserver === "undefined") {
      return;
    }
    this.resizeObserver?.disconnect();
    this.resizeObserver = new ResizeObserver(() => {
      this.requestRender();
    });
    this.resizeObserver.observe(this.canvas);
  }

  requestRender() {
    this.needsRender = true;
    if (this.animationFrame !== 0) {
      return;
    }
    this.animationFrame = requestAnimationFrame(() => {
      this.animationFrame = 0;
      if (!this.needsRender) {
        return;
      }
      this.needsRender = false;
      this.resize();
      this.draw();
    });
  }

  drawNow() {
    this.requestRender();
  }

  draw() {
    const drawStart = performance.now();
    if (!this.device ||
        !this.depthTexture ||
        !this.markerDepthTexture ||
        !this.markerPipeline ||
        !this.markerBindGroup ||
        !this.bindGroup ||
        !this.brickRequestBitsetBuffer ||
        !this.brickRequestListBuffer ||
        !this.brickRequestReadbackBuffer) {
      return;
    }

    this.brickAtlas?.beginFrame(this.frameIndex);
    this.device.queue.writeBuffer(this.brickRequestBitsetBuffer, 0, this.brickRequestBitsetClearData);
    this.device.queue.writeBuffer(this.brickRequestListBuffer, 0, this.brickRequestListClearData);
    const encoder = this.device.createCommandEncoder();
    const colorView = this.context.getCurrentTexture().createView();
    if (this.hasScene) {
      this.updateUniforms();
    }

    const markerPass = encoder.beginRenderPass({
      colorAttachments: [{
        view: colorView,
        clearValue: { r: 0.05, g: 0.13, b: 0.21, a: 1 },
        loadOp: "clear",
        storeOp: "store"
      }],
      depthStencilAttachment: {
        view: this.markerDepthTexture.createView(),
        depthClearValue: 1,
        depthLoadOp: "clear",
        depthStoreOp: "store"
      }
    });
    if (this.hasScene &&
        this.markerInstanceCount > 0 &&
        this.markerVertexBuffer &&
        this.markerIndexBuffer &&
        this.markerInstanceBuffer) {
      markerPass.setPipeline(this.markerPipeline);
      markerPass.setBindGroup(0, this.markerBindGroup);
      markerPass.setVertexBuffer(0, this.markerVertexBuffer);
      markerPass.setVertexBuffer(1, this.markerInstanceBuffer);
      markerPass.setIndexBuffer(this.markerIndexBuffer, "uint16");
      markerPass.drawIndexed(this.markerIndexCount, this.markerInstanceCount);
    }
    markerPass.end();

    const volumePass = encoder.beginRenderPass({
      colorAttachments: [{
        view: colorView,
        loadOp: "load",
        storeOp: "store"
      }],
      depthStencilAttachment: {
        view: this.depthTexture.createView(),
        depthClearValue: 1,
        depthLoadOp: "clear",
        depthStoreOp: "store"
      }
    });

    if (this.hasScene) {
      volumePass.setPipeline(this.pipeline);
      volumePass.setBindGroup(0, this.bindGroup);
      volumePass.setVertexBuffer(0, this.vertexBuffer);
      volumePass.setIndexBuffer(this.indexBuffer, "uint16");
      volumePass.drawIndexed(this.indexCount);
    }

    volumePass.end();
    const shouldReadBack = this.hasScene &&
      !this.brickRequestReadbackInFlight &&
      this.frameIndex % BRICK_REQUEST_READBACK_INTERVAL === 0;
    if (this.hasScene && this.brickRequestReadbackInFlight) {
      this.readbackSkippedWhileInFlight = true;
      this.profile.skippedReadbacks += 1;
    }
    if (shouldReadBack) {
      encoder.copyBufferToBuffer(
        this.brickRequestListBuffer,
        0,
        this.brickRequestReadbackBuffer,
        0,
        this.brickRequestListByteLength
      );
      this.brickRequestReadbackInFlight = true;
    }
    this.device.queue.submit([encoder.finish()]);
    this.recordProfile("drawCpuMs", performance.now() - drawStart);
    this.profile.frames += 1;
    this.frameIndex += 1;

    if (shouldReadBack) {
      this.readBackBrickRequests();
    }
  }

  updateUniforms() {
    const aspect = this.canvas.width / Math.max(1, this.canvas.height);
    const projection = perspectiveWebGPU(45 * Math.PI / 180, aspect, 0.05, 1000);
    const view = translation(this.panX, this.panY, -this.distance);
    const model = matrixFromQuaternion(this.orientation);
    const modelView = multiply(view, model);
    const mvp = multiply(projection, modelView);
    const cameraTexture = this.cameraPositionInTextureSpace();
    const atlasAxis = this.brickAtlas?.atlasBricksPerAxis || 1;
    const brickSize = this.brickAtlas?.brickSize || 1;
    const overlap = this.brickAtlas?.manifest?.bricking?.overlap ?? 0;
    const textureSize = this.brickAtlas?.textureSize || 1;
    const borderSize = this.level0Size.map((size) => (overlap + 1) / Math.max(1, size));
    const cubeMin = this.clipMin.map((value, index) => value + borderSize[index]);
    const cubeMax = this.clipMax.map((value, index) => value - borderSize[index]);
    for (let index = 0; index < 3; index += 1) {
      if (cubeMax[index] <= cubeMin[index]) {
        const center = (cubeMin[index] + cubeMax[index]) * 0.5;
        cubeMin[index] = Math.max(borderSize[index], center - 0.0005);
        cubeMax[index] = Math.min(1 - borderSize[index], center + 0.0005);
      }
    }
    const clipScale = cubeMax.map((value, index) => value - cubeMin[index]);
    const clipTranslation = cubeMax.map((value, index) => 0.5 * (value + cubeMin[index] - 1));
    const clipMatrix = scaleTranslation(clipScale[0], clipScale[1], clipScale[2], clipTranslation[0], clipTranslation[1], clipTranslation[2]);
    const lodFactor = 2.0 * Math.tan(0.75 / 2.0) * this.screenSpaceError / Math.max(this.canvas.width, 1);
    this.device.queue.writeBuffer(this.uniformBuffer, 0, new Float32Array([
      ...mvp,
      ...clipMatrix,
      cameraTexture[0], cameraTexture[1], cameraTexture[2], 0,
      this.level0BrickCount[0], this.level0BrickCount[1], this.level0BrickCount[2], 0,
      atlasAxis, brickSize, overlap, textureSize,
      this.level0Size[0], this.level0Size[1], this.level0Size[2], 0,
      cubeMin[0], cubeMin[1], cubeMin[2], 0,
      cubeMax[0], cubeMax[1], cubeMax[2], 0,
      this.levelCount, lodFactor, this.levelZeroWorldSpaceError, 1,
      this.transferBias, this.renderMode, this.isoValue, 1,
      this.volumeHalfExtent[0], this.volumeHalfExtent[1], this.volumeHalfExtent[2], 0
    ]));
    if (this.markerUniformBuffer) {
      this.device.queue.writeBuffer(
        this.markerUniformBuffer,
        0,
        new Float32Array([...mvp, ...modelView])
      );
    }
  }

  async readBackBrickRequests() {
    const readbackBuffer = this.brickRequestReadbackBuffer;
    const listCapacity = this.brickRequestListCapacity;
    const totalBrickCount = this.totalBrickCount;
    const atlas = this.brickAtlas;
    const atlasGeneration = atlas?.generation ?? 0;
    try {
      const mapStart = performance.now();
      await readbackBuffer.mapAsync(GPUMapMode.READ);
      this.recordProfile("readbackMapMs", performance.now() - mapStart);
      if (readbackBuffer !== this.brickRequestReadbackBuffer ||
          atlasGeneration !== (this.brickAtlas?.generation ?? 0)) {
        readbackBuffer.unmap();
        return;
      }
      const values = new Uint32Array(readbackBuffer.getMappedRange());
      const processStart = performance.now();
      const rawCount = values[0];
      const readableCount = Math.min(rawCount, listCapacity);
      const requests = Array.from(values.slice(1, readableCount + 1))
        .filter((brickIndex) => brickIndex < totalBrickCount);
      const overflowText = rawCount > listCapacity
        ? `, overflow ${rawCount - listCapacity}`
        : "";
      this.profile.readbacks += 1;
      this.profile.requestedBricks += requests.length;
      if (rawCount > listCapacity) {
        this.profile.readbackOverflows += 1;
      }
      atlas?.requestBricks(requests);
      this.recordProfile("readbackProcessMs", performance.now() - processStart);
      if (this.statusReporting) {
        const atlasSummary = atlas ? `; ${atlas.summary()}` : "";
        this.reportStatus(
          `GPU readback: ${requests.length} requests${overflowText}${atlasSummary}`
        );
      }
      readbackBuffer.unmap();
    } catch (error) {
      if (readbackBuffer === this.brickRequestReadbackBuffer &&
          atlasGeneration === (this.brickAtlas?.generation ?? 0)) {
        this.reportStatus(`GPU compact readback failed: ${error.message ?? String(error)}`);
      }
    } finally {
      if (readbackBuffer === this.brickRequestReadbackBuffer) {
        this.brickRequestReadbackInFlight = false;
        if (this.readbackSkippedWhileInFlight) {
          this.readbackSkippedWhileInFlight = false;
          this.requestRender();
        }
      }
    }
  }

  cameraPositionInTextureSpace() {
    const cameraWorld = [-this.panX, -this.panY, this.distance];
    const inverseOrientation = conjugateQuaternion(this.orientation);
    const cameraLocal = rotateVectorByQuaternion(cameraWorld, inverseOrientation);
    return [
      cameraLocal[0] / Math.max(1e-6, 2 * this.volumeHalfExtent[0]) + 0.5,
      cameraLocal[1] / Math.max(1e-6, 2 * this.volumeHalfExtent[1]) + 0.5,
      cameraLocal[2] / Math.max(1e-6, 2 * this.volumeHalfExtent[2]) + 0.5
    ];
  }

  applyArcballRotation(clientX, clientY) {
    if (!this.dragStartVector || !this.dragStartOrientation) {
      return;
    }
    const currentVector = this.projectPointerToArcball(clientX, clientY);
    const axis = cross(this.dragStartVector, currentVector);
    const axisLength = Math.hypot(axis[0], axis[1], axis[2]);
    if (axisLength < 1e-6) {
      this.orientation = this.dragStartOrientation;
      return;
    }
    const dotValue = clamp(dot(this.dragStartVector, currentVector), -1, 1);
    const angle = Math.atan2(axisLength, dotValue);
    const delta = quaternionFromAxisAngle(axis.map((value) => value / axisLength), angle);
    this.orientation = normalizeQuaternion(multiplyQuaternions(delta, this.dragStartOrientation));
  }

  projectPointerToArcball(clientX, clientY) {
    const rect = this.canvas.getBoundingClientRect();
    const diameter = Math.max(1, Math.min(rect.width, rect.height));
    const x = (2 * (clientX - rect.left) - rect.width) / diameter;
    const y = (rect.height - 2 * (clientY - rect.top)) / diameter;
    const lengthSquared = x * x + y * y;
    if (lengthSquared <= 1) {
      return [x, y, Math.sqrt(1 - lengthSquared)];
    }
    const length = Math.sqrt(lengthSquared);
    return [x / length, y / length, 0];
  }

  recordProfile(key, value) {
    if (this.profilingEnabled) {
      this.profile[key] += value;
    }
  }
}

function createRendererProfile() {
  return {
    frames: 0,
    drawCpuMs: 0,
    readbacks: 0,
    readbackMapMs: 0,
    readbackProcessMs: 0,
    requestedBricks: 0,
    readbackOverflows: 0,
    skippedReadbacks: 0
  };
}

function perspectiveWebGPU(fovy, aspect, near, far) {
  const f = 1 / Math.tan(fovy / 2);
  return [
    f / aspect, 0, 0, 0,
    0, f, 0, 0,
    0, 0, far / (near - far), -1,
    0, 0, (far * near) / (near - far), 0
  ];
}

function translation(x, y, z) {
  return [
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    x, y, z, 1
  ];
}

function scaleTranslation(xScale, yScale, zScale, xTranslation, yTranslation, zTranslation) {
  return [
    xScale, 0, 0, 0,
    0, yScale, 0, 0,
    0, 0, zScale, 0,
    xTranslation, yTranslation, zTranslation, 1
  ];
}

function multiply(a, b) {
  const out = new Array(16).fill(0);
  for (let column = 0; column < 4; column += 1) {
    for (let row = 0; row < 4; row += 1) {
      for (let index = 0; index < 4; index += 1) {
        out[column * 4 + row] += a[index * 4 + row] * b[column * 4 + index];
      }
    }
  }
  return out;
}

function quaternionFromAxisAngle(axis, angle) {
  const halfAngle = angle * 0.5;
  const s = Math.sin(halfAngle);
  return [axis[0] * s, axis[1] * s, axis[2] * s, Math.cos(halfAngle)];
}

function multiplyQuaternions(a, b) {
  return [
    a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
    a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
    a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
    a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2]
  ];
}

function conjugateQuaternion(quaternion) {
  return [-quaternion[0], -quaternion[1], -quaternion[2], quaternion[3]];
}

function rotateVectorByQuaternion(vector, quaternion) {
  const rotated = multiplyQuaternions(
    multiplyQuaternions(quaternion, [vector[0], vector[1], vector[2], 0]),
    conjugateQuaternion(quaternion)
  );
  return [rotated[0], rotated[1], rotated[2]];
}

function normalizeQuaternion(quaternion) {
  const length = Math.hypot(quaternion[0], quaternion[1], quaternion[2], quaternion[3]);
  if (length === 0) {
    return [0, 0, 0, 1];
  }
  return quaternion.map((value) => value / length);
}

function normalizeVector(vector) {
  const length = Math.hypot(vector[0], vector[1], vector[2]);
  if (length === 0) {
    return [0, 0, 1];
  }
  return vector.map((value) => value / length);
}

function dot(a, b) {
  return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

function cross(a, b) {
  return [
    a[1] * b[2] - a[2] * b[1],
    a[2] * b[0] - a[0] * b[2],
    a[0] * b[1] - a[1] * b[0]
  ];
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

function midpoint(a, b) {
  return {
    x: (a.x + b.x) * 0.5,
    y: (a.y + b.y) * 0.5
  };
}

function pointDistance(a, b) {
  return Math.hypot(a.x - b.x, a.y - b.y);
}

function preferredDeviceLimits(adapterLimits) {
  const requiredLimits = {};
  const maxBufferSize = adapterLimits.maxBufferSize ?? 0;
  if (maxBufferSize > 0) {
    requiredLimits.maxBufferSize = maxBufferSize;
  }

  const maxStorageBufferBindingSize = Math.min(
    adapterLimits.maxStorageBufferBindingSize ?? maxBufferSize,
    maxBufferSize || Number.MAX_SAFE_INTEGER
  );
  if (maxStorageBufferBindingSize > 0) {
    requiredLimits.maxStorageBufferBindingSize = maxStorageBufferBindingSize;
  }
  return requiredLimits;
}

function isAppleMobileDevice() {
  const userAgent = navigator.userAgent || "";
  const platform = navigator.platform || "";
  return /iPhone|iPad|iPod/.test(userAgent) ||
    (platform === "MacIntel" && navigator.maxTouchPoints > 1);
}

function renderPixelRatio() {
  const ratio = window.devicePixelRatio || 1;
  return isAppleMobileDevice() ? Math.min(ratio, APPLE_MOBILE_RENDER_PIXEL_RATIO) : ratio;
}

function limitSnapshot(limits) {
  return {
    maxBufferSize: limits.maxBufferSize,
    maxStorageBufferBindingSize: limits.maxStorageBufferBindingSize,
    maxTextureDimension3D: limits.maxTextureDimension3D,
    maxTextureArrayLayers: limits.maxTextureArrayLayers
  };
}

function webGPULimitSummary(prefix, limits) {
  return `${prefix}: buffer ${formatMiB(limits.maxBufferSize)}, storage binding ${formatMiB(limits.maxStorageBufferBindingSize)}, 3D texture ${limits.maxTextureDimension3D}`;
}

function formatMiB(byteCount) {
  if (!Number.isFinite(byteCount)) {
    return "unknown";
  }
  return `${(byteCount / (1024 * 1024)).toFixed(1)} MiB`;
}

function normalizeManifestRanges(manifest) {
  const volume = manifest.volume ?? {};
  const bytesPerComponent = Math.max(1, volume.bytesPerComponent ?? 1);
  const byteRangeMax = (2 ** (8 * bytesPerComponent)) - 1;
  const valueRange = Array.isArray(volume.valueRange)
    ? volume.valueRange
    : (Array.isArray(volume.dataRange) ? volume.dataRange : [0, byteRangeMax]);
  const dataRange = Array.isArray(volume.dataRange) ? volume.dataRange : [0, byteRangeMax];
  const dataRangeMax = Math.max(byteRangeMax, dataRange[1] ?? 0, valueRange[1] ?? 0);

  return {
    ...manifest,
    volume: {
      ...volume,
      valueRange,
      dataRange: [0, dataRangeMax]
    }
  };
}

function normalizeManifestForRenderer(manifest) {
  return normalizeManifestBricks(normalizeManifestLevels(normalizeManifestRanges(manifest)));
}

function normalizeManifestBricks(manifest) {
  if (Array.isArray(manifest.bricks)) {
    return manifest;
  }

  const values = manifest.brickMetadata?.values;
  if (!Array.isArray(values)) {
    return manifest;
  }

  const brickCount = Math.floor(values.length / 3);
  const bricks = new Array(brickCount);
  for (let index = 0; index < brickCount; index += 1) {
    const offset = index * 3;
    bricks[index] = {
      index,
      min: values[offset] ?? 0,
      max: values[offset + 1] ?? values[offset] ?? 0,
      byteLength: values[offset + 2] ?? 0
    };
  }

  return {
    ...manifest,
    bricks
  };
}

function normalizeManifestLevels(manifest) {
  const volumeSize = manifest.volume?.size;
  const brickSize = manifest.bricking?.brickSize;
  const overlap = manifest.bricking?.overlap ?? 0;
  if (!Array.isArray(volumeSize) || volumeSize.length < 3 || !Number.isFinite(brickSize)) {
    return manifest;
  }

  const computedLevels = computeBorgVRLevels(volumeSize, brickSize, overlap);
  const computedBrickTotal = computedLevels.reduce((sum, level) => sum + level.brickTotal, 0);
  const manifestBrickTotal = Array.isArray(manifest.bricks)
    ? manifest.bricks.length
    : (manifest.levels ?? []).reduce((sum, level) => sum + (level.brickTotal ?? brickTotal(level.brickCount)), 0);

  if (computedBrickTotal !== manifestBrickTotal) {
    return manifest;
  }

  return {
    ...manifest,
    levels: computedLevels
  };
}

function computeBorgVRLevels(volumeSize, brickSize, overlap) {
  let levelSize = volumeSize.map((value) => Math.max(1, Math.floor(value)));
  const level0BrickCount = calculateOutputBrickCount(levelSize, brickSize, overlap);
  const maxBrickCount = Math.max(...level0BrickCount);
  const levelCount = maxBrickCount <= 1 ? 1 : 1 + Math.ceil(Math.log2(maxBrickCount));
  const levels = [];
  let firstBrick = 0;

  for (let level = 0; level < levelCount; level += 1) {
    const brickCount = calculateOutputBrickCount(levelSize, brickSize, overlap);
    const brickTotalValue = brickTotal(brickCount);
    levels.push({
      level,
      size: levelSize,
      brickCount,
      firstBrick,
      brickTotal: brickTotalValue
    });
    firstBrick += brickTotalValue;
    levelSize = levelSize.map((value) => Math.max(1, Math.floor((value + 1) / 2)));
  }

  return levels;
}

function calculateOutputBrickCount(size, brickSize, overlap) {
  const effectiveBrickSize = Math.max(1, brickSize - 2 * overlap);
  return size.map((value) => Math.max(1, Math.ceil(value / effectiveBrickSize)));
}

function brickTotal(brickCount) {
  if (!Array.isArray(brickCount) || brickCount.length < 3) {
    return 0;
  }
  return Math.max(1, brickCount[0] ?? 1) *
    Math.max(1, brickCount[1] ?? 1) *
    Math.max(1, brickCount[2] ?? 1);
}

function createLevelDataArrayBuffer({ volumeSize, brickSize, overlap, levels }) {
  const normalizedLevels = [...(levels?.length ? levels : [{
    level: 0,
    brickCount: [1, 1, 1],
    firstBrick: 0,
    size: volumeSize
  }])].sort((a, b) => (a.level ?? 0) - (b.level ?? 0));
  const buffer = new ArrayBuffer(Math.max(1, normalizedLevels.length) * LEVEL_DATA_STRIDE);
  const view = new DataView(buffer);
  const effectiveBrickSizeValue = Math.max(1, brickSize - 2 * overlap);

  for (let index = 0; index < normalizedLevels.length; index += 1) {
    const level = normalizedLevels[index];
    const offset = index * LEVEL_DATA_STRIDE;
    const brickCount = level.brickCount ?? [1, 1, 1];
    const levelSize = level.size ?? volumeSize.map((value) => Math.max(1, Math.ceil(value / (2 ** index))));
    view.setUint32(offset + 0, Math.max(1, brickCount[0] ?? 1), true);
    view.setUint32(offset + 4, Math.max(1, (brickCount[0] ?? 1) * (brickCount[1] ?? 1)), true);
    view.setUint32(offset + 8, Math.max(0, level.firstBrick ?? 0), true);
    view.setUint32(offset + 12, 0, true);
    view.setFloat32(offset + 16, Math.max(1, levelSize[0] ?? 1) / effectiveBrickSizeValue, true);
    view.setFloat32(offset + 20, Math.max(1, levelSize[1] ?? 1) / effectiveBrickSizeValue, true);
    view.setFloat32(offset + 24, Math.max(1, levelSize[2] ?? 1) / effectiveBrickSizeValue, true);
    view.setFloat32(offset + 28, 0, true);
  }

  return buffer;
}

function matrixFromQuaternion(quaternion) {
  const [x, y, z, w] = quaternion;
  const xx = x * x;
  const yy = y * y;
  const zz = z * z;
  const xy = x * y;
  const xz = x * z;
  const yz = y * z;
  const wx = w * x;
  const wy = w * y;
  const wz = w * z;

  return [
    1 - 2 * (yy + zz), 2 * (xy + wz), 2 * (xz - wy), 0,
    2 * (xy - wz), 1 - 2 * (xx + zz), 2 * (yz + wx), 0,
    2 * (xz + wy), 2 * (yz - wx), 1 - 2 * (xx + yy), 0,
    0, 0, 0, 1
  ];
}

/*
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of Duisburg-Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of this
 software and associated documentation files (the "Software"), to deal in the Software
 without restriction, including without limitation the rights to use, copy, modify,
 merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 permit persons to whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included in all copies or
 substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
 BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
 OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
 IN THE SOFTWARE.
 */
